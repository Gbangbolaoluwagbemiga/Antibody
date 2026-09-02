// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BaselineMath} from "./libraries/BaselineMath.sol";
import {IAntibodySignal} from "./interfaces/IAntibodySignal.sol";

/// @title AntibodyHook
/// @author cripticdev — UHI10, project HK-UHI10-1010
/// @notice A Uniswap v4 hook that makes MEV extraction unprofitable by pricing it, using a
///         threshold the pool computes for itself from its own trading history.
///
/// @dev ── What this does and does not claim ──────────────────────────────────────────────────
///
///      A hook has no mempool visibility and cannot pause, queue, or reorder a swap. It can only
///      observe what has already executed. So Antibody does not prevent sandwich attacks; it
///      identifies the attacker's *closing leg* and taxes it, routing the proceeds to the pool's
///      liquidity providers. The victim's fill has already happened by then. What is destroyed is
///      the attacker's profit, which is what makes the strategy stop being worth running.
///
///      ── Why there is no custody ────────────────────────────────────────────────────────────
///
///      The penalty is applied through Uniswap v4's native dynamic-fee override, so it accrues to
///      LPs through the pool's own fee growth. This hook never holds funds, has no withdrawal
///      path, and takes no `BeforeSwapDelta`. That removes an entire class of bug rather than
///      guarding against it.
///
///      ── Why the state write cannot be skipped ──────────────────────────────────────────────
///
///      Transient storage is scoped to a single transaction; a sandwich spans three. Cross-
///      transaction detection therefore requires real storage stamped with `block.number`. The
///      SSTORE that enables detection is the same one that updates the baseline, so the two cannot
///      come apart: a lazy or deferred baseline update would visibly break detection, and the
///      tests would catch it.
contract AntibodyHook is BaseHook, Ownable, IAntibodySignal {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error NotDynamicFeePool();
    error ParameterOutOfBounds();

    // ─────────────────────────────────────────────────────────────────────────────
    // Bounds — enforced in the setters, not merely documented
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Hard ceiling on the total LP fee this hook will ever return: 5%.
    /// @dev Deliberately far below `LPFeeLibrary.MAX_LP_FEE` (100%). This is a constant, not an
    ///      owner-settable value, so no key compromise can turn the hook into a confiscation
    ///      device. A hook that *can* charge 100% is not a fee mechanism, it is a honeypot.
    uint24 public constant MAX_TOTAL_FEE = 50_000;

    uint24 public constant MIN_BASE_FEE = 100; // 0.01%
    uint8 public constant MIN_K = 2;
    uint8 public constant MAX_K = 10;
    uint32 public constant MIN_SAMPLE_FLOOR = 8;
    uint32 public constant MAX_SAMPLE_FLOOR = 1_000;

    /// @notice How long a confirmed sandwich exit keeps costing its author, across every pool.
    /// @dev ~14 hours at Unichain's ~1s blocks. Long enough that moving to a fresh pool inside one
    ///      trading session does not shake it off; short enough that it is unmistakably memory
    ///      rather than a ban. Nothing here is owner-settable.
    uint32 public constant IMMUNITY_WINDOW = 50_000;

    /// @notice Surcharge per confirmed exit, before decay.
    uint24 public constant IMMUNITY_STEP = 5_000; // 0.50%

    /// @notice Confirmed exits beyond this stop compounding.
    /// @dev A bound is not politeness. Without it the surcharge grows without limit and the design
    ///      becomes an unbounded punishment, which is exactly what the fee ceiling exists to stop.
    uint32 public constant MAX_REMEMBERED_EXITS = 4;

    /// @notice Blocks over which the recency surcharge decays to nothing.
    /// @dev The surcharge halves each block, so it is already negligible well before this bound;
    ///      the explicit window makes "zero after 8 blocks" a testable statement rather than an
    ///      artifact of integer shifting.
    uint8 public constant DECAY_WINDOW = 8;

    /// @notice Distinct addresses a pool must have served before it can vaccinate another.
    /// @dev Swap count alone is worthless as a qualification: one address trading against itself
    ///      twenty times satisfies it for the price of gas. Distinct traders cost an attacker one
    ///      funded address each, which is not expensive but is no longer free.
    uint32 public constant MIN_DONOR_TRADERS = 5;

    /// @notice Blocks a pool must exist before it can vaccinate another.
    /// @dev Roughly 90 minutes at Unichain's ~1s blocks. Time is the one input an attacker cannot
    ///      manufacture, and it prevents claiming a pair's donor slot in a single transaction.
    uint32 public constant MIN_DONOR_AGE = 5_000;

    // ─────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice One slot. The pool's self-computed opinion of its own normal behaviour.
    struct Baseline {
        uint64 ewmaSizeRatio; // mean size-to-liquidity, 1e18
        uint64 ewmaDeviation; // mean absolute deviation of the above
        uint64 ewmaImpact; // mean realized |tick| movement, secondary metric
        uint32 sampleCount; // swaps observed; gates the statistical detector
        uint32 lastBlock; // last block this pool saw a swap
    }

    /// @notice One slot. Drives both the structural detector and the recency surcharge.
    struct TraderRecord {
        uint32 lastBlock;
        bool lastZeroForOne;
        uint64 lastSizeRatio;
    }

    /// @notice One slot. Pool-level last swap, identity-independent.
    /// @dev Separate from `TraderRecord` so an attacker splitting legs across two EOAs is still
    ///      visible: the *pool* saw a reversal even if no single address did.
    /// @notice The pool's current in-block "run": a stretch of swaps all pushing the same way.
    /// @dev Replaces a plain record of the previous swap, which could not distinguish a sandwich
    ///      from two arbitrageurs crossing. See `_classify` for the measurement that forced this.
    ///
    ///      `runVictim` is the load-bearing field: a *second, distinct* address that traded in the
    ///      same direction as whoever opened the run. That is the third party a sandwich needs in
    ///      order to be a sandwich. Without one there is nobody to extract from.
    ///
    ///      Held in real storage, not transient. A sandwich spans three transactions, and tstore is
    ///      scoped to one, so transient storage cannot see across the legs.
    struct PoolLastSwap {
        uint32 lastBlock;
        bool runZeroForOne;
        address runOpener;
        address runVictim;
    }

    /// @notice What a trader carries with them, independent of any pool.
    /// @dev Held against the address rather than the pool, which is the entire point: a per-pool
    ///      baseline can be escaped by moving to a pool that has never seen you.
    struct Immunity {
        uint32 confirmedExits;
        uint32 lastFlaggedBlock;
    }

    mapping(address => Immunity) public immunity;

    /// @notice Best-characterised pool per token pair — the donor a new pool inherits from.
    /// @dev Keyed on the currency pair rather than the full PoolKey: fee tier and tick spacing
    ///      change the pool, not the asset's behaviour, and size-relative-to-liquidity is already
    ///      normalised against each pool's own depth.
    mapping(bytes32 => PoolId) public pairDonor;

    /// @notice Pools whose opening baseline was inherited rather than observed.
    /// @dev Marked, and stays marked. A pool holding an opinion it did not earn is a different
    ///      thing from one that did, and an integrator who cannot tell them apart is being misled.
    mapping(PoolId => bool) public vaccinated;

    /// @notice What a pool has actually earned, as opposed to how many swaps happened in it.
    struct PoolQuality {
        uint32 distinctTraders;
        uint32 createdBlock;
    }

    mapping(PoolId => PoolQuality) public poolQuality;

    mapping(PoolId => Baseline) public baselines;
    mapping(PoolId => PoolLastSwap) public poolLastSwap;
    mapping(PoolId => mapping(address => TraderRecord)) public traderRecords;

    /// @notice Band width in mean-absolute-deviations. Bounded by [MIN_K, MAX_K].
    uint8 public k = 3;

    /// @notice Swaps a pool must observe before the statistical detector activates.
    uint32 public minSamples = 20;

    /// @notice LP fee charged when nothing is flagged.
    uint24 public baseFee = 3_000; // 0.30%

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event ParametersUpdated(uint8 k, uint32 minSamples, uint24 baseFee);

    /// @notice A new pool opened with a baseline inherited from an established sibling.
    event BaselineInherited(PoolId indexed poolId, PoolId indexed donor, uint256 thresholdScore);

    // ─────────────────────────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) Ownable(_owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // reject non-dynamic-fee pools at creation
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            // No delta flags. This hook never takes a cut of the swap; the penalty rides the
            // native LP fee, so there is nothing to settle and nothing to withdraw.
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Callbacks
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Refuse to serve a pool that was not created with `DYNAMIC_FEE_FLAG`. Without it the
    ///      PoolManager silently ignores the fee override and every penalty this hook computes
    ///      would be discarded — the hook would appear to work while doing nothing at all.
    ///      Failing at initialization is the only place this can be caught loudly.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();

        // ── Vaccination ──────────────────────────────────────────────────────────────────────
        // Cold start is the most targetable hole in any learned-threshold design, and it is
        // targetable *because* the design is documented: an attacker reads that the statistical
        // detector stays silent until `minSamples`, then waits for a fresh pool.
        //
        // Refusing to have an opinion is right when there is nothing to base one on. A pool
        // trading a pair an established sibling has already characterised is not in that
        // position — so it opens with that sibling's baseline and is defended from swap one.
        bytes32 pair = keccak256(abi.encode(key.currency0, key.currency1));
        PoolId newPool = key.toId();
        PoolId donor = pairDonor[pair];

        // Age is measured from here, and it is the one qualification an attacker cannot fabricate.
        poolQuality[newPool].createdBlock = uint32(block.number);

        if (PoolId.unwrap(donor) == bytes32(0)) {
            // First pool on this pair. It is the provisional donor, but that claim confers nothing
            // until it qualifies, and it can be displaced by any pool that qualifies better.
            pairDonor[pair] = newPool;
            return BaseHook.beforeInitialize.selector;
        }

        Baseline memory d = baselines[donor];

        // Only a pool that earned its baseline can confer one. Passing along an unearned opinion
        // would launder a guess into something that looks like evidence, which is precisely the
        // failure this project exists to remove.
        if (_isEligibleDonor(donor)) {
            baselines[newPool] = Baseline({
                ewmaSizeRatio: d.ewmaSizeRatio,
                ewmaDeviation: d.ewmaDeviation,
                ewmaImpact: d.ewmaImpact,
                // Enough to make the detector live, and no more. Claiming the donor's full sample
                // count would assert experience this pool has not had.
                sampleCount: minSamples,
                lastBlock: uint32(block.number)
            });
            vaccinated[newPool] = true;
            emit BaselineInherited(newPool, donor, _thresholdOf(baselines[newPool]));
        }

        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // Record the pre-swap tick so `_afterSwap` can measure realized impact. Same transaction,
        // so transient storage is the correct tool here — unlike cross-transaction detection.
        (, int24 tickBefore,,) = poolManager.getSlot0(poolId);
        _setTransientTick(poolId, tickBefore);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        uint256 ratio = BaselineMath.sizeRatio(_absAmount(params.amountSpecified), liquidity);

        (IAntibodySignal.Signal signal, uint24 penalty, uint256 thresholdScore) =
            _assess(poolId, _trader(), params.zeroForOne, ratio);

        uint24 fee = baseFee + penalty;
        if (fee > MAX_TOTAL_FEE) fee = MAX_TOTAL_FEE;

        if (signal != IAntibodySignal.Signal.None) {
            emit ToxicFlowDetected(poolId, _trader(), signal, ratio, thresholdScore, penalty);
        }

        // `afterSwap` needs to know what was concluded here in order to record a confirmed exit.
        // Same transaction, so transient storage is the right tool — unlike the cross-transaction
        // detection above, which cannot use it.
        _setTransientSignal(poolId, uint8(signal));

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev The load-bearing callback. Three storage writes, every one of them consumed by the
    ///      next swap's detection path.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        address trader = _trader();

        uint128 liquidity = poolManager.getLiquidity(poolId);
        uint256 ratio = BaselineMath.sizeRatio(_absAmount(params.amountSpecified), liquidity);

        (, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        uint256 impact = BaselineMath.tickDistance(_getTransientTick(poolId), tickAfter);

        Baseline memory b = baselines[poolId];

        // Deviation is folded in against the *previous* mean, before the mean absorbs this sample.
        // Updating the mean first would understate the deviation of every observation.
        b.ewmaDeviation = BaselineMath.ewma(b.ewmaDeviation, BaselineMath.absDiff(b.ewmaSizeRatio, ratio));
        b.ewmaSizeRatio = BaselineMath.ewma(b.ewmaSizeRatio, ratio);
        b.ewmaImpact = BaselineMath.ewma(b.ewmaImpact, impact);
        if (b.sampleCount < type(uint32).max) b.sampleCount += 1;
        b.lastBlock = uint32(block.number);

        baselines[poolId] = b;

        _recordBreadth(key, poolId, trader);

        traderRecords[poolId][trader] = TraderRecord({
            lastBlock: uint32(block.number),
            lastZeroForOne: params.zeroForOne,
            lastSizeRatio: uint64(ratio)
        });

        _advanceRun(poolId, params.zeroForOne, trader);

        _recordConfirmedExit(poolId, trader);

        emit BaselineUpdated(
            poolId,
            b.ewmaSizeRatio,
            b.ewmaDeviation,
            b.ewmaImpact,
            _thresholdOf(b),
            b.sampleCount
        );

        return (BaseHook.afterSwap.selector, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Detection
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Detectors run strongest-first and the first match wins, so a confirmed sandwich exit is
    ///      never downgraded to a weaker classification.
    function _assess(PoolId poolId, address trader, bool zeroForOne, uint256 ratio)
        private
        view
        returns (IAntibodySignal.Signal signal, uint24 penalty, uint256 thresholdScore)
    {
        Baseline memory b = baselines[poolId];
        thresholdScore = _thresholdOf(b);

        TraderRecord memory tr = traderRecords[poolId][trader];
        PoolLastSwap memory pl = poolLastSwap[poolId];

        // ── Signal 1: this address reversed its own position in the same block, AND somebody
        // else traded the pool in between.
        //
        // That last clause is the whole difference between a sandwich and a round trip. A sandwich
        // is defined by its victim: attacker buys, a third party fills at the worsened price,
        // attacker sells. Without an intervening trade there is no one to extract from — the
        // position simply opened and closed, which is ordinary behaviour for a rebalancing market
        // maker or a multi-hop route that revisits the same pool.
        //
        // Omitting this check flagged 23 consecutive ordinary swaps at the maximum penalty on
        // Unichain Sepolia before it was caught. `poolLastSwap` records the most recent swap in
        // this pool from any address, so "someone else went between my two legs" is exactly
        // `pl.lastTrader != trader` within the current block.
        //
        // The intervening trade must also run in the *same* direction as this trader's entry.
        // That is what separates a victim from a bystander, and it is an economic distinction
        // rather than a cosmetic one: a sandwich pays only when the trade in the middle pushes
        // price the way the entry already pushed it. If the middle trade ran the other way, this
        // trader lost to it rather than extracted from it, and calling that a sandwich is simply
        // wrong. Found by an adversarial test for round-trip arbitrage, which the earlier rule
        // convicted regardless of which way the trade between the legs went.
        if (
            tr.lastBlock == uint32(block.number) && tr.lastZeroForOne != zeroForOne
                && pl.lastBlock == uint32(block.number) && pl.runVictim != address(0)
                && pl.runVictim != trader && pl.runZeroForOne == tr.lastZeroForOne
        ) {
            return (IAntibodySignal.Signal.SandwichExit, MAX_TOTAL_FEE - baseFee, thresholdScore);
        }

        // ── Signal 2: the pool reversed direction within the block, against a victim.
        //
        // Catches an attacker who splits entry and exit across two EOAs, which measurement says is
        // not an edge case but the norm: 610 live mainnet blocks produced 25 sandwich-shaped
        // events and every one was multi-address. Zero were same-origin. Resolving the actual
        // senders confirmed it is deliberate — all 25 exits used a *fresh* address, and no
        // (entry, exit) pair ever repeated. Address rotation is the standard evasion.
        //
        // The `runVictim` clause is not decoration, and this is the second time this project has
        // learned that lesson. The condition shipped originally was "the pool reversed direction
        // under a different address", which is also a plain description of two arbitrageurs
        // crossing in a busy block. Replaying it over 321 real mainnet blocks:
        //
        //     as shipped        recall 23/23 (100%)   fired on 35/298 ordinary blocks   precision  40%
        //     victim-gated      recall 18/23  (78%)   fired on  0/298 ordinary blocks   precision 100%
        //
        // So it was firing on 11.7% of ordinary blocks, and around three fifths of everything it
        // flagged was innocent. That is the same defect as the 23-of-23 false positives above,
        // with a different variable name: a rule that describes an attack and ordinary behaviour
        // equally well.
        //
        // The gate costs 5 of 23 in recall, and that is a deliberate trade rather than a
        // regression. Those 5 are lost to the O(1) state a hook can afford — an offline pass with
        // the whole block in view keeps all 23 at zero false positives, but `afterSwap` sees one
        // swap and two storage words, so some interleavings are unrecoverable. Given the choice,
        // precision wins: a false positive here overcharges an innocent trader, which is precisely
        // the "coarse rule engine driven by subjective inputs" criticism this design exists to
        // answer. Missing an attack costs the pool nothing it was not already losing.
        //
        // Priced at three quarters of the span rather than the maximum: same-origin is *proof* of
        // common control, a gated reversal is *inference*, and charging identically for proof and
        // inference would be sloppy.
        if (
            pl.lastBlock == uint32(block.number) && pl.runZeroForOne != zeroForOne
                && pl.runVictim != address(0) && pl.runVictim != trader
        ) {
            uint24 inferred = ((MAX_TOTAL_FEE - baseFee) * 3) / 4;
            uint24 withCarry = inferred + _immunitySurcharge(trader);
            return (
                IAntibodySignal.Signal.BlockReversal,
                withCarry > MAX_TOTAL_FEE - baseFee ? MAX_TOTAL_FEE - baseFee : withCarry,
                thresholdScore
            );
        }

        // Carried across pools. Added to whatever this pool concluded locally, because a known
        // sandwicher making an otherwise unremarkable trade is precisely the case a per-pool
        // baseline cannot see.
        uint24 carried = _immunitySurcharge(trader);

        // ── Signal 3: statistical. Suppressed entirely until the pool has enough history.
        // A baseline with no data has no opinion; asserting one anyway is exactly the
        // "subjective input" this project exists to eliminate.
        if (b.sampleCount >= minSamples && thresholdScore > 0 && ratio > thresholdScore) {
            uint256 excess = ratio - thresholdScore;
            // Penalty scales with how far past the pool's own band the trade sits, reaching the
            // ceiling at 2x the threshold. Proportional, not a cliff.
            uint24 ceiling = MAX_TOTAL_FEE - baseFee;
            uint256 scaled = (uint256(ceiling) * excess) / thresholdScore;
            uint256 total = (scaled > ceiling ? ceiling : scaled) + _recencySurcharge(tr);

            // Cap AFTER adding the surcharge, not before. Capping only the anomaly component let
            // the sum exceed the ceiling: the swap was still charged correctly, because
            // `_beforeSwap` clamps the final fee — but the emitted event reported a penalty that
            // was never applied (observed on-chain at 70500 against a 47000 ceiling). That event
            // is the public signal this hook exists to publish, and a router or a dashboard
            // consuming it would have been reading a number the chain never charged.
            total += carried;
            return (
                IAntibodySignal.Signal.SizeAnomaly,
                total > ceiling ? ceiling : uint24(total),
                thresholdScore
            );
        }

        // Nothing local fired, but the trader arrived with history.
        if (carried > 0) {
            return (IAntibodySignal.Signal.CrossPoolMemory, carried, thresholdScore);
        }

        return (IAntibodySignal.Signal.None, 0, thresholdScore);
    }

    /// @notice Time-weighted component: trading the same pool again within a few blocks costs more.
    /// @dev This is the honest form of "time-weighted execution" for a v4 hook. A hook cannot delay
    ///      a swap, but it can make temporal clustering — which sandwiching and toxic bursts both
    ///      require — progressively expensive. Halves per block, hard zero after DECAY_WINDOW.
    ///      Applied only on top of a statistical flag, never on its own, so an honest trader who
    ///      simply trades often is never penalised for frequency alone.
    function _recencySurcharge(TraderRecord memory tr) private view returns (uint24) {
        if (tr.lastBlock == 0) return 0; // never seen: no recency to weigh
        uint256 elapsed = block.number - uint256(tr.lastBlock);
        if (elapsed >= DECAY_WINDOW) return 0;
        return uint24(((MAX_TOTAL_FEE - baseFee) / 2) >> elapsed);
    }

    /// @notice Write the cross-pool record, if this swap was a confirmed sandwich exit.
    /// @dev Extracted from `_afterSwap` because inlining it pushed that function past the EVM's
    ///      stack limit. A confirmed exit is the only thing that earns a record: a size anomaly is
    ///      not evidence of sandwiching, and treating it as such would let ordinary large traders
    ///      accumulate a surcharge for doing nothing wrong.
    function _recordConfirmedExit(PoolId poolId, address trader) private {
        if (_getTransientSignal(poolId) != uint8(IAntibodySignal.Signal.SandwichExit)) return;

        Immunity memory im = immunity[trader];
        unchecked {
            if (im.confirmedExits < type(uint32).max) im.confirmedExits += 1;
        }
        im.lastFlaggedBlock = uint32(block.number);
        immunity[trader] = im;

        emit ImmunityRecorded(trader, im.confirmedExits, poolId);
    }

    /// @notice What this trader's confirmed sandwich history costs them here, right now.
    /// @dev Linear decay to exactly zero at `IMMUNITY_WINDOW`. Decay is the property that keeps
    ///      this a fading surcharge rather than a blacklist — a permanent mark would be a
    ///      censorship surface and a thing worth capturing. Anyone can age out of it by not
    ///      sandwiching for a while, and no owner can extend, clear, or target it.
    function _immunitySurcharge(address trader) private view returns (uint24) {
        Immunity memory im = immunity[trader];
        if (im.confirmedExits == 0) return 0;

        uint256 elapsed = block.number - uint256(im.lastFlaggedBlock);
        if (elapsed >= IMMUNITY_WINDOW) return 0;

        uint256 remembered = im.confirmedExits > MAX_REMEMBERED_EXITS ? MAX_REMEMBERED_EXITS : im.confirmedExits;
        uint256 full = remembered * IMMUNITY_STEP;
        uint256 decayed = (full * (IMMUNITY_WINDOW - elapsed)) / IMMUNITY_WINDOW;

        uint24 ceiling = MAX_TOTAL_FEE - baseFee;
        return decayed > ceiling ? ceiling : uint24(decayed);
    }

    /// @notice Whether a pool has earned the right to confer its baseline on a new one.
    /// @dev The original gate was `sampleCount >= minSamples`, which an attacker satisfies by
    ///      trading against themselves twenty times in a pool they seeded with dust. Because the
    ///      donor slot was also permanent, whoever created the first pool on a pair owned it
    ///      forever and could author the baseline every later pool would inherit — wide enough
    ///      that the anomaly detector never fires. That is not a degraded defence, it is a
    ///      disabled one, and it was found by an adversarial test rather than by reading the code.
    ///
    ///      Qualification now costs something in all three dimensions an attacker would have to
    ///      fake: breadth (distinct addresses), time (pool age), and observed history.
    /// @notice Count a pool's distinct traders, and hand the pair's donor slot to whichever pool
    ///         serves the most of them.
    /// @dev Extracted from `_afterSwap` because it pushed that function past the stack limit —
    ///      worth noting rather than hiding, since the fix is structural and not cosmetic.
    ///
    ///      Both the count and the displacement check only run when an address appears in this
    ///      pool for the first time, which is rare once a pool has warmed up. Reconsidering the
    ///      donor on every swap would put extra reads in the hot path to answer a question whose
    ///      input had not changed.
    /// @dev Advance the pool's in-block run by one swap.
    ///
    ///      A "run" is a maximal stretch of same-direction swaps inside one block. Opening a run
    ///      records who started it; a *different* address then pushing the same way is recorded as
    ///      `runVictim`, because that is the trade a sandwich exists to extract from. A reversal
    ///      ends the run and starts the next one, clearing the victim with it.
    ///
    ///      Two storage words, written once per swap, regardless of how busy the block is.
    function _advanceRun(PoolId poolId, bool zeroForOne, address trader) private {
        PoolLastSwap memory pl = poolLastSwap[poolId];

        if (pl.lastBlock != uint32(block.number) || pl.runZeroForOne != zeroForOne) {
            // A new block, or a reversal within this one: either way, this swap opens a fresh run.
            poolLastSwap[poolId] = PoolLastSwap({
                lastBlock: uint32(block.number),
                runZeroForOne: zeroForOne,
                runOpener: trader,
                runVictim: address(0)
            });
            return;
        }

        // Continuing the run. Only a second, distinct address counts — the opener trading again in
        // their own direction is not a victim of anything.
        if (trader != pl.runOpener && pl.runVictim != trader) {
            pl.runVictim = trader;
            poolLastSwap[poolId] = pl;
        }
    }

    function _recordBreadth(PoolKey calldata key, PoolId poolId, address trader) private {
        if (traderRecords[poolId][trader].lastBlock != 0) return;

        uint32 breadth;
        unchecked {
            breadth = poolQuality[poolId].distinctTraders + 1;
        }
        poolQuality[poolId].distinctTraders = breadth;

        bytes32 pair = keccak256(abi.encode(key.currency0, key.currency1));
        PoolId incumbent = pairDonor[pair];

        // The slot is no longer permanent. A pool serving more of the market than the incumbent
        // takes over as the reference, so squatting the first pool on a pair buys nothing once
        // real usage shows up.
        if (
            PoolId.unwrap(incumbent) != PoolId.unwrap(poolId)
                && breadth > poolQuality[incumbent].distinctTraders
        ) {
            pairDonor[pair] = poolId;
        }
    }

    function _isEligibleDonor(PoolId poolId) private view returns (bool) {
        Baseline memory b = baselines[poolId];
        PoolQuality memory q = poolQuality[poolId];

        if (b.sampleCount < minSamples) return false;
        if (q.distinctTraders < MIN_DONOR_TRADERS) return false;
        if (q.createdBlock == 0) return false;
        if (block.number - uint256(q.createdBlock) < MIN_DONOR_AGE) return false;

        return true;
    }

    function _thresholdOf(Baseline memory b) private view returns (uint256) {
        if (b.sampleCount < minSamples) return 0;
        return BaselineMath.threshold(b.ewmaSizeRatio, b.ewmaDeviation, k);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // IAntibodySignal views
    // ─────────────────────────────────────────────────────────────────────────────

    function currentThreshold(PoolId poolId) external view returns (uint256) {
        return _thresholdOf(baselines[poolId]);
    }

    function isCalibrated(PoolId poolId) external view returns (bool) {
        return baselines[poolId].sampleCount >= minSamples;
    }

    /// @notice Quote the fee a swap would be charged right now, without executing it.
    /// @dev Exists for the demo UI's before/after panel. It is a convenience read over the same
    ///      `_assess` the swap path uses — not a substitute for it, and not where any state lives.
    function quote(PoolId poolId, address trader, bool zeroForOne, uint256 amountAbs)
        external
        view
        returns (IAntibodySignal.Signal signal, uint24 totalFee, uint256 observedScore, uint256 thresholdScore)
    {
        uint256 ratio = BaselineMath.sizeRatio(amountAbs, poolManager.getLiquidity(poolId));
        uint24 penalty;
        (signal, penalty, thresholdScore) = _assess(poolId, trader, zeroForOne, ratio);
        totalFee = baseFee + penalty;
        if (totalFee > MAX_TOTAL_FEE) totalFee = MAX_TOTAL_FEE;
        observedScore = ratio;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Owner controls — bounded, so the ceiling holds even if the key does not
    // ─────────────────────────────────────────────────────────────────────────────

    function setParameters(uint8 _k, uint32 _minSamples, uint24 _baseFee) external onlyOwner {
        if (_k < MIN_K || _k > MAX_K) revert ParameterOutOfBounds();
        if (_minSamples < MIN_SAMPLE_FLOOR || _minSamples > MAX_SAMPLE_FLOOR) revert ParameterOutOfBounds();
        if (_baseFee < MIN_BASE_FEE || _baseFee > MAX_TOTAL_FEE) revert ParameterOutOfBounds();

        k = _k;
        minSamples = _minSamples;
        baseFee = _baseFee;

        emit ParametersUpdated(_k, _minSamples, _baseFee);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev The swap `sender` reported to a hook is the *router*, not the person. Every user of a
    ///      shared router would collapse into one identity, which would make the structural
    ///      detectors fire constantly on unrelated traffic. `tx.origin` is the transaction
    ///      submitter and is the correct primitive here: a sandwich requires separately submitted
    ///      transactions, so the submitter is exactly what we need to distinguish.
    ///
    ///      The known cost is that account-abstraction bundles and multi-EOA attackers do not
    ///      resolve to a stable identity. That is precisely why `Signal.BlockReversal` exists at
    ///      the pool level: it needs no identity at all.
    function _trader() private view returns (address) {
        // slither-disable-next-line tx-origin
        // SAFETY: `tx.origin` is used here as a *heuristic grouping key*, never for authorization.
        // Nothing is granted, transferred, or permitted on the basis of this value. The worst a
        // spoofed or unexpected value can do is misclassify one swap's fee tier — bounded above by
        // MAX_TOTAL_FEE, and never able to revert the swap. The usual `tx.origin` attack (a
        // malicious intermediary contract impersonating the user's authority) has no purchase
        // because there is no authority here to impersonate. Access control is `onlyPoolManager`,
        // enforced separately and tested in AntibodyAccessControl.t.sol.
        return tx.origin;
    }

    function _absAmount(int256 amountSpecified) private pure returns (uint256) {
        unchecked {
            return amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        }
    }

    function _transientSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode("antibody.tickBefore", poolId));
    }

    function _signalSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode("antibody.signal", poolId));
    }

    function _setTransientSignal(PoolId poolId, uint8 signal) private {
        bytes32 slot = _signalSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, signal)
        }
    }

    function _getTransientSignal(PoolId poolId) private view returns (uint8 signal) {
        bytes32 slot = _signalSlot(poolId);
        assembly ("memory-safe") {
            signal := tload(slot)
        }
    }

    function _setTransientTick(PoolId poolId, int24 tick) private {
        bytes32 slot = _transientSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, tick)
        }
    }

    function _getTransientTick(PoolId poolId) private view returns (int24 tick) {
        bytes32 slot = _transientSlot(poolId);
        assembly ("memory-safe") {
            tick := tload(slot)
        }
    }
}

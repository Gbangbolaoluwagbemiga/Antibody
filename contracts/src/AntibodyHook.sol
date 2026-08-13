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

    /// @notice Blocks over which the recency surcharge decays to nothing.
    /// @dev The surcharge halves each block, so it is already negligible well before this bound;
    ///      the explicit window makes "zero after 8 blocks" a testable statement rather than an
    ///      artifact of integer shifting.
    uint8 public constant DECAY_WINDOW = 8;

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
    struct PoolLastSwap {
        uint32 lastBlock;
        bool lastZeroForOne;
        address lastTrader;
    }

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
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
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

        traderRecords[poolId][trader] = TraderRecord({
            lastBlock: uint32(block.number),
            lastZeroForOne: params.zeroForOne,
            lastSizeRatio: uint64(ratio)
        });

        poolLastSwap[poolId] =
            PoolLastSwap({lastBlock: uint32(block.number), lastZeroForOne: params.zeroForOne, lastTrader: trader});

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

        // ── Signal 1: this address reversed its own position, same block, same pool.
        // The on-chain signature of a sandwich's exit leg. Structural, so it is live from the
        // pool's very first swap — it needs no statistical history to be meaningful.
        if (tr.lastBlock == uint32(block.number) && tr.lastZeroForOne != zeroForOne) {
            return (IAntibodySignal.Signal.SandwichExit, MAX_TOTAL_FEE - baseFee, thresholdScore);
        }

        // ── Signal 2: the pool reversed direction within the block, under a different address.
        // Catches an attacker who splits the legs across two EOAs. Weaker, because honest
        // same-block arbitrage looks identical — so it draws half the penalty, never the maximum.
        if (pl.lastBlock == uint32(block.number) && pl.lastZeroForOne != zeroForOne && pl.lastTrader != trader) {
            return (IAntibodySignal.Signal.BlockReversal, (MAX_TOTAL_FEE - baseFee) / 2, thresholdScore);
        }

        // ── Signal 3: statistical. Suppressed entirely until the pool has enough history.
        // A baseline with no data has no opinion; asserting one anyway is exactly the
        // "subjective input" this project exists to eliminate.
        if (b.sampleCount >= minSamples && thresholdScore > 0 && ratio > thresholdScore) {
            uint256 excess = ratio - thresholdScore;
            // Penalty scales with how far past the pool's own band the trade sits, reaching the
            // ceiling at 2x the threshold. Proportional, not a cliff.
            uint256 scaled = (uint256(MAX_TOTAL_FEE - baseFee) * excess) / thresholdScore;
            uint24 anomalyPenalty = scaled > MAX_TOTAL_FEE - baseFee ? MAX_TOTAL_FEE - baseFee : uint24(scaled);

            return (IAntibodySignal.Signal.SizeAnomaly, anomalyPenalty + _recencySurcharge(tr), thresholdScore);
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

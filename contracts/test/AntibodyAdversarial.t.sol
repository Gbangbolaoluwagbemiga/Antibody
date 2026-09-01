// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {AntibodyHook} from "../src/AntibodyHook.sol";
import {IAntibodySignal} from "../src/interfaces/IAntibodySignal.sol";

/// @notice Adversarial tests written to attack the design rather than confirm it.
///
/// @dev These exist because the last three real defects in this project were all found by running
///      against a real chain, never by a test written to pass. So these are written to fail, and
///      what they find is treated as a finding rather than a nuisance.
contract AntibodyAdversarialTest is BaseTest {
    using EasyPosm for *;

    AntibodyHook internal hook;

    Currency internal c0;
    Currency internal c1;

    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");
    address internal arb = makeAddr("arbitrageur");
    address internal other = makeAddr("other");
    address internal lp = makeAddr("lp");

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant TYPICAL = 1e18;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags ^ (0x7777 << 144));
        deployCodeTo("AntibodyHook.sol:AntibodyHook", abi.encode(poolManager, owner), hookAddress);
        hook = AntibodyHook(hookAddress);

        _fund(attacker);
        _fund(arb);
        _fund(other);
        vm.roll(3_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Finding 1 — the donor slot is claimable, and the baseline it confers is forgeable
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev REGRESSION for the original hole. Before the eligibility gate, an attacker created the
    ///      first pool on a pair, traded against themselves twenty times at a size of their
    ///      choosing, and every honest pool created afterwards inherited a band wide enough that
    ///      the anomaly detector never fired. Not a degraded defence — a disabled one.
    ///
    ///      One address and no age now confers nothing.
    function test_forgedBaseline_fromASelfDealtPool_confersNothing() public {
        PoolKey memory attackerPool = _pool(60);

        for (uint256 i = 0; i < hook.minSamples() + 2; i++) {
            vm.roll(block.number + 1);
            _swap(attackerPool, attacker, true, TYPICAL * 300);
        }

        assertGt(hook.currentThreshold(attackerPool.toId()), 0, "the pool has a baseline");

        PoolKey memory honestPool = _pool(10);
        PoolId honestId = honestPool.toId();

        assertFalse(hook.vaccinated(honestId), "but it has not earned the right to pass it on");
        assertEq(hook.currentThreshold(honestId), 0, "the honest pool starts with no opinion, as it should");

        // And the detector in the honest pool is not disabled — it simply has not calibrated yet,
        // which is the documented, honest starting state rather than a poisoned one.
        (IAntibodySignal.Signal signal,,,) = hook.quote(honestId, other, true, TYPICAL * 50);
        assertEq(uint8(signal), uint8(IAntibodySignal.Signal.None));
    }

    /// @dev RESIDUAL RISK, stated precisely rather than claimed away. The gate raises the cost of
    ///      claiming a donor slot; it does not make it impossible. An attacker willing to fund
    ///      MIN_DONOR_TRADERS addresses and wait MIN_DONOR_AGE blocks still qualifies.
    ///
    ///      What the fix actually buys is that the slot is no longer *permanent*: the moment a
    ///      pool serving more of the market exists, it becomes the reference. Squatting is now
    ///      expensive, temporary, and defeated by ordinary usage rather than by anything the hook
    ///      has to detect.
    function test_residual_attackerCanQualifyButCannotHoldTheSlot() public {
        PoolKey memory squatter = _pool(60);

        // The cost of qualifying: distinct funded addresses, plus time.
        for (uint256 i = 0; i < hook.MIN_DONOR_TRADERS(); i++) {
            address sybil = address(uint160(uint256(keccak256(abi.encode("sybil", i)))));
            _fund(sybil);
            for (uint256 j = 0; j < 5; j++) {
                vm.roll(block.number + 1);
                _swap(squatter, sybil, true, TYPICAL * 300);
            }
        }
        vm.roll(block.number + hook.MIN_DONOR_AGE());

        PoolKey memory victimPool = _pool(10);
        assertTrue(hook.vaccinated(victimPool.toId()), "a funded, patient attacker still qualifies");

        // But ordinary usage takes the slot away from them.
        PoolKey memory realPool = _pool(200);
        for (uint256 i = 0; i < hook.MIN_DONOR_TRADERS() + 3; i++) {
            address trader = address(uint160(uint256(keccak256(abi.encode("real", i)))));
            _fund(trader);
            vm.roll(block.number + 1);
            _swap(realPool, trader, true, TYPICAL);
        }

        bytes32 pair = keccak256(abi.encode(c0, c1));
        assertEq(
            PoolId.unwrap(hook.pairDonor(pair)),
            PoolId.unwrap(realPool.toId()),
            "the pool serving more of the market becomes the reference"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Finding 2 — how far does a false positive travel?
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev A two-pool arbitrage touches each pool once, in one direction. Neither pool sees a
    ///      same-trader reversal, so the structural detector should stay silent. Confirming that
    ///      the common arb shape is NOT caught.
    function test_crossPoolArbitrage_isNotFlagged() public {
        PoolKey memory poolA = _pool(60);
        PoolKey memory poolB = _pool(10);
        _calibrate(poolA);
        _calibrate(poolB);

        // Classic shape: buy here, sell there, same block.
        _swap(poolA, arb, true, TYPICAL);
        _swap(poolB, arb, false, TYPICAL);

        (uint32 exits,) = hook.immunity(arb);
        assertEq(exits, 0, "a two-pool arb must not register as a sandwich");
    }

    /// @dev NARROWED, NOT ELIMINATED — and on reflection this is the correct call.
    ///
    ///      A round trip through one pool with a *same-direction* trade in between still registers
    ///      as extraction, and it should. Whatever the trader intended, the middle trade pushed
    ///      price the way their entry already had, and they closed against it: that is the sandwich
    ///      payoff, and intent is not observable on chain. The direction check removed the case
    ///      where the middle trade ran the other way — there the trader lost to it rather than
    ///      profited, and convicting them was simply wrong.
    ///
    ///      So the honest statement is that Antibody prices this pattern by its economics rather
    ///      than by its label, and an arbitrageur who closes a loop through one pool across an
    ///      intervening same-direction trade will pay. That belongs in the limitations, not in a
    ///      claim that it never happens.
    function test_sameDirectionRoundTrip_isTreatedAsExtraction() public {
        PoolKey memory poolA = _pool(60);
        _calibrate(poolA);

        _swap(poolA, arb, true, TYPICAL * 2); // leg one of the route
        _swap(poolA, other, true, TYPICAL); // unrelated flow, in between
        _swap(poolA, arb, false, TYPICAL * 2); // route closes through the same pool

        (uint32 exits,) = hook.immunity(arb);
        assertEq(exits, 1, "FINDING: a same-pool round-trip arb is recorded as a confirmed sandwich exit");
    }

    /// @dev The blast radius, measured rather than asserted. This is the shared-memory feature
    ///      working as designed — and simultaneously the cost of a wrong call, which is now paid
    ///      across every pool the hook serves rather than in one.
    ///
    ///      Both readings are true and the number is the same, so the test records it plainly:
    ///      whatever put the record there, the address pays roughly 2.7x in a pool that had
    ///      nothing to do with it, until the memory decays.
    function test_confirmedExit_costsTheAddressInUnrelatedPools() public {
        PoolKey memory poolA = _pool(60);
        PoolKey memory poolB = _pool(10);
        _calibrate(poolA);

        // The round-trip route above, which the detector treats as a sandwich.
        _swap(poolA, arb, true, TYPICAL * 2);
        _swap(poolA, other, true, TYPICAL);
        _swap(poolA, arb, false, TYPICAL * 2);

        // An ordinary, unremarkable trade in a completely different pool.
        (, uint24 arbFee,,) = hook.quote(poolB.toId(), arb, true, TYPICAL / 10);
        (, uint24 cleanFee,,) = hook.quote(poolB.toId(), other, true, TYPICAL / 10);

        assertGt(arbFee, cleanFee, "FINDING: the penalty travels to an unrelated pool");
        emit log_named_uint("arb pays (pips)", arbFee);
        emit log_named_uint("everyone else pays (pips)", cleanFee);
    }

    /// @dev The bystander case the direction check is for: someone trades between the legs, but
    ///      the other way. This trader lost to that trade rather than extracted from it, so it is
    ///      not a sandwich and must not be recorded as one.
    function test_oppositeDirectionBystander_isNotASandwich() public {
        PoolKey memory poolA = _pool(60);
        _calibrate(poolA);

        _swap(poolA, arb, true, TYPICAL * 2);
        _swap(poolA, other, false, TYPICAL); // runs against the entry, not with it
        _swap(poolA, arb, false, TYPICAL * 2);

        (uint32 exits,) = hook.immunity(arb);
        assertEq(exits, 0, "a trade that moved price against the entry is not a victim");
    }

    /// @dev Donor eligibility after the fix: twenty self-dealt swaps in a fresh pool must no
    ///      longer qualify anyone to vaccinate.
    function test_selfDealtPool_cannotVaccinate() public {
        PoolKey memory attackerPool = _pool(60);
        for (uint256 i = 0; i < hook.minSamples() + 2; i++) {
            vm.roll(block.number + 1);
            _swap(attackerPool, attacker, true, TYPICAL * 300);
        }

        PoolKey memory honestPool = _pool(10);
        assertFalse(hook.vaccinated(honestPool.toId()), "one address and no age must confer nothing");
        assertEq(hook.currentThreshold(honestPool.toId()), 0, "the honest pool starts with no opinion");
    }

    /// @dev And the slot is no longer permanent: a pool serving more of the market displaces the
    ///      squatter as the pair's reference.
    function test_betterQualifiedPoolDisplacesTheSquatter() public {
        PoolKey memory squatter = _pool(60);
        for (uint256 i = 0; i < hook.minSamples() + 2; i++) {
            vm.roll(block.number + 1);
            _swap(squatter, attacker, true, TYPICAL * 300);
        }

        PoolKey memory real = _pool(10);
        for (uint256 i = 0; i < 8; i++) {
            address trader = address(uint160(uint256(keccak256(abi.encode("trader", i)))));
            _fund(trader);
            for (uint256 j = 0; j < 4; j++) {
                vm.roll(block.number + 1);
                _swap(real, trader, true, TYPICAL);
            }
        }

        bytes32 pair = keccak256(abi.encode(c0, c1));
        assertEq(
            PoolId.unwrap(hook.pairDonor(pair)),
            PoolId.unwrap(real.toId()),
            "the pool serving more distinct traders becomes the reference"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Repricing, driven by mainnet measurement
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Scanning 610 live mainnet blocks containing Uniswap v3 swaps turned up 25
    ///      sandwich-shaped events. Every single one split its entry and exit across *different*
    ///      addresses. Zero were same-origin.
    ///
    ///      That inverts the original penalty ordering. `SandwichExit` carried the maximum on the
    ///      reasoning that same-origin is the strongest evidence, and `BlockReversal` carried half
    ///      because honest same-block arbitrage can look identical. Both halves of that reasoning
    ///      still hold — but the shape drawing half the penalty is the one production attackers
    ///      actually use, because splitting addresses is how they evade same-origin detection.
    ///
    ///      So BlockReversal is repriced to three quarters. Not the full maximum: same-origin is
    ///      *proof* of common control while a pool-level reversal is *inference*, and charging
    ///      identically for proof and inference would be sloppy. But half was under-pricing the
    ///      only form the data actually shows.
    function test_blockReversal_isPricedForTheThreatThatActuallyOccurs() public {
        PoolKey memory pool = _pool(60);
        _calibrate(pool);

        uint24 span = hook.MAX_TOTAL_FEE() - hook.baseFee();

        // Attacker enters, victim follows, a *different* address closes the position.
        _swap(pool, attacker, true, TYPICAL * 2);
        _swap(pool, other, true, TYPICAL);

        vm.recordLogs();
        _swap(pool, arb, false, TYPICAL * 2); // the accomplice

        (IAntibodySignal.Signal signal, uint24 penalty) = _lastFlag();
        assertEq(uint8(signal), uint8(IAntibodySignal.Signal.BlockReversal), "multi-address reversal must fire");
        assertEq(penalty, (span * 3) / 4, "repriced to three quarters of the span");
        assertGt(penalty, span / 2, "strictly more than the old half-penalty");
        assertLt(penalty, span, "but still below a proven same-origin sandwich");
    }

    /// @dev The ordering that must survive the repricing: proof still costs more than inference.
    function test_sameOriginStillCostsMoreThanInference() public {
        PoolKey memory pool = _pool(60);
        _calibrate(pool);

        _swap(pool, attacker, true, TYPICAL * 2);
        _swap(pool, other, true, TYPICAL);
        vm.recordLogs();
        _swap(pool, attacker, false, TYPICAL * 2);
        (IAntibodySignal.Signal sameSignal, uint24 samePenalty) = _lastFlag();

        assertEq(uint8(sameSignal), uint8(IAntibodySignal.Signal.SandwichExit));
        assertEq(samePenalty, hook.MAX_TOTAL_FEE() - hook.baseFee(), "same-origin keeps the ceiling");
        assertGt(samePenalty, ((hook.MAX_TOTAL_FEE() - hook.baseFee()) * 3) / 4, "proof outranks inference");
    }

    /// @dev Pull the most recent ToxicFlowDetected out of the recorded logs.
    function _lastFlag() internal returns (IAntibodySignal.Signal signal, uint24 penalty) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics.length > 0 && logs[i - 1].topics[0] == IAntibodySignal.ToxicFlowDetected.selector) {
                (uint8 raw,,, uint24 p) = abi.decode(logs[i - 1].data, (uint8, uint256, uint256, uint24));
                return (IAntibodySignal.Signal(raw), p);
            }
        }
        revert("no ToxicFlowDetected emitted");
    }

    // ─────────────────────────────────────────────────────────────────────────────

    function _pool(int24 tickSpacing) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, SQRT_PRICE_1_1);
        positionManager.mint(
            key,
            TickMath.minUsableTick(tickSpacing),
            TickMath.maxUsableTick(tickSpacing),
            100_000e18,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            ""
        );
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(c0)).mint(who, 50_000_000e18);
        MockERC20(Currency.unwrap(c1)).mint(who, 50_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(PoolKey memory key, address who, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(who, who);
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, key, "", who, block.timestamp + 1);
    }

    function _calibrate(PoolKey memory key) internal {
        for (uint256 i = 0; i < hook.minSamples() + 3; i++) {
            vm.roll(block.number + 1);
            _swap(key, other, true, TYPICAL);
        }
    }
}

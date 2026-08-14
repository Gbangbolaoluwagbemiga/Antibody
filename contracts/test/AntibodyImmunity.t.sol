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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {AntibodyHook} from "../src/AntibodyHook.sol";
import {IAntibodySignal} from "../src/interfaces/IAntibodySignal.sol";

/// @notice Cross-pool immunity: a pool that gets attacked makes every other pool smarter.
///
/// @dev Per-pool baselines have a hole, and it is the obvious one: attack pool A, get priced, move
///      to pool B. A pool that has never seen you prices you as a stranger. Every learned-threshold
///      design has this problem unless the memory outlives the pool that formed it.
///
///      So a confirmed `SandwichExit` writes a record against the *trader*, held by the hook rather
///      than by any pool, and every pool the hook serves consults it. Attack one, all of them
///      remember.
///
///      The memory decays. That is not a softening — it is what keeps the design's safety
///      properties intact. A permanent mark would be a blacklist, which is a censorship surface and
///      a governance target; decay means the worst case is a temporary surcharge that anyone can
///      age out of by behaving normally. The swap still executes, the ceiling still binds, and no
///      owner can set any of it.
contract AntibodyImmunityTest is BaseTest {
    using EasyPosm for *;
    using StateLibrary for IPoolManager;

    AntibodyHook internal hook;

    PoolKey internal poolA;
    PoolKey internal poolB;
    PoolId internal idA;
    PoolId internal idB;

    Currency internal currency0;
    Currency internal currency1;

    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");
    address internal honest = makeAddr("honest");
    address internal stranger = makeAddr("stranger");

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant TYPICAL = 1e18;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags ^ (0x5555 << 144));
        deployCodeTo("AntibodyHook.sol:AntibodyHook", abi.encode(poolManager, owner), hookAddress);
        hook = AntibodyHook(hookAddress);

        poolA = _pool(60);
        poolB = _pool(10); // same hook, same tokens, different pool
        idA = poolA.toId();
        idB = poolB.toId();

        _fund(attacker);
        _fund(victim);
        _fund(honest);
        _fund(stranger);

        vm.roll(1_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // The record forms
    // ─────────────────────────────────────────────────────────────────────────────

    function test_confirmedSandwich_writesTraderMemory() public {
        (uint32 before_,) = hook.immunity(attacker);
        assertEq(before_, 0, "no history before the attack");

        _sandwich(poolA);

        (uint32 exits, uint32 lastBlock) = hook.immunity(attacker);
        assertEq(exits, 1, "a confirmed sandwich exit must be recorded against the trader");
        assertEq(lastBlock, uint32(block.number));
    }

    /// @dev Only a *confirmed* exit counts. A size anomaly is not evidence of sandwiching, and
    ///      treating it as such would let ordinary large traders accumulate a permanent-feeling
    ///      surcharge for doing nothing wrong.
    function test_sizeAnomalyAlone_doesNotWriteMemory() public {
        _calibrate(poolA);

        _swap(poolA, honest, true, TYPICAL * 400); // deep into anomaly territory

        (uint32 exits,) = hook.immunity(honest);
        assertEq(exits, 0, "an oversized trade is not a sandwich");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // The memory travels — the whole point
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev The headline. Pool B has never seen this address. It prices them anyway.
    function test_immunity_travelsToAPoolThatNeverSawTheAttacker() public {
        _calibrate(poolB);

        (, uint24 strangerFee,,) = hook.quote(idB, stranger, true, TYPICAL);
        assertEq(strangerFee, hook.baseFee(), "an unknown trader pays base fee in pool B");

        // Attack happens entirely in pool A.
        _sandwich(poolA);

        (IAntibodySignal.Signal signal, uint24 attackerFee,,) = hook.quote(idB, attacker, true, TYPICAL);

        assertGt(attackerFee, strangerFee, "pool B must price the attacker above an unknown trader");
        assertEq(
            uint8(signal),
            uint8(IAntibodySignal.Signal.CrossPoolMemory),
            "the surcharge must be attributed, not silent"
        );
    }

    /// @dev Repeat offences compound, up to a bound. Without the bound this becomes an unbounded
    ///      punishment, which is the thing the fee ceiling exists to prevent.
    function test_immunity_compoundsButIsBounded() public {
        _sandwich(poolA);
        (, uint24 once,,) = hook.quote(idB, attacker, true, TYPICAL);

        vm.roll(block.number + 5);
        _sandwich(poolA);
        (, uint24 twice,,) = hook.quote(idB, attacker, true, TYPICAL);

        assertGt(twice, once, "a second confirmed sandwich must cost more than the first");

        for (uint256 i = 0; i < 10; i++) {
            vm.roll(block.number + 5);
            _sandwich(poolA);
        }
        (, uint24 many,,) = hook.quote(idB, attacker, true, TYPICAL);
        assertLe(many, hook.MAX_TOTAL_FEE(), "compounding must never breach the ceiling");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // It is memory, not a blacklist
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Decay is the property that keeps this from being a censorship surface. A mark that
    ///      never fades is a blacklist, and a blacklist is something worth capturing.
    function test_immunity_decaysToNothing() public {
        _sandwich(poolA);
        (, uint24 fresh,,) = hook.quote(idB, attacker, true, TYPICAL);
        assertGt(fresh, hook.baseFee(), "the memory is live immediately after the attack");

        vm.roll(block.number + hook.IMMUNITY_WINDOW() / 2);
        (, uint24 half,,) = hook.quote(idB, attacker, true, TYPICAL);
        assertLt(half, fresh, "the memory must fade with distance");
        assertGt(half, hook.baseFee(), "but it is still present halfway through the window");

        vm.roll(block.number + hook.IMMUNITY_WINDOW());
        (IAntibodySignal.Signal signal, uint24 expired,,) = hook.quote(idB, attacker, true, TYPICAL);
        assertEq(expired, hook.baseFee(), "past the window the trader is a stranger again");
        assertEq(uint8(signal), uint8(IAntibodySignal.Signal.None));
    }

    /// @dev The benign-failure guarantee has to survive this feature. A flagged trader is charged
    ///      more; they are never refused.
    function test_immunity_neverBlocksASwap() public {
        _calibrate(poolB);
        _sandwich(poolA);

        // Must not revert.
        _swap(poolB, attacker, true, TYPICAL);

        (,,, uint32 samples,) = hook.baselines(idB);
        assertGt(samples, 0, "the attacker's swap still executed and was still observed");
    }

    function test_immunity_leavesUnrelatedTradersAlone() public {
        _calibrate(poolB);
        _sandwich(poolA);

        (IAntibodySignal.Signal signal, uint24 fee,,) = hook.quote(idB, honest, true, TYPICAL);
        assertEq(uint8(signal), uint8(IAntibodySignal.Signal.None));
        assertEq(fee, hook.baseFee(), "someone else's history must never touch an innocent trader");
    }

    function testFuzz_immunity_neverBreachesCeiling(uint256 amount, uint32 elapsed) public {
        _calibrate(poolB);
        _sandwich(poolA);

        amount = bound(amount, 0.001 ether, 5_000 ether);
        vm.roll(block.number + bound(elapsed, 0, hook.IMMUNITY_WINDOW() * 2));

        (, uint24 fee,,) = hook.quote(idB, attacker, true, amount);
        assertLe(fee, hook.MAX_TOTAL_FEE());
        assertGe(fee, hook.baseFee());
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _pool(int24 tickSpacing) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
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
        MockERC20(Currency.unwrap(currency0)).mint(who, 5_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(who, 5_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(PoolKey memory key, address who, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(who, who);
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, key, "", who, block.timestamp + 1);
    }

    function _calibrate(PoolKey memory key) internal {
        for (uint256 i = 0; i < hook.minSamples() + 3; i++) {
            vm.roll(block.number + 1);
            _swap(key, honest, true, TYPICAL);
        }
    }

    /// @dev A full sandwich, victim included — without a third party between the legs there is no
    ///      sandwich to confirm.
    function _sandwich(PoolKey memory key) internal {
        _swap(key, attacker, true, TYPICAL * 5);
        _swap(key, victim, true, TYPICAL);
        _swap(key, attacker, false, TYPICAL * 5);
    }
}

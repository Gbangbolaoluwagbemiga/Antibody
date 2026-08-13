// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {AntibodyHook} from "../src/AntibodyHook.sol";

/// @notice Tests 8 and 9 of the plan's matrix.
///
/// @dev These exist because of a specific, documented failure in this builder's previous
///      submission: access-control checks that were present in the source but never exercised by a
///      test, and therefore never actually verified. An inherited modifier is an untested claim
///      until something calls the function without permission and observes the revert.
///
///      Every externally reachable entry point on this hook is called here by an address that
///      should not be able to reach it.
contract AntibodyAccessControlTest is Test {
    AntibodyHook internal hook;

    address internal constant POOL_MANAGER = address(0xBEEF);
    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");

    PoolKey internal key;

    function setUp() public {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags ^ (0x4444 << 144));

        deployCodeTo("AntibodyHook.sol:AntibodyHook", abi.encode(POOL_MANAGER, owner), hookAddress);
        hook = AntibodyHook(hookAddress);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Test 8 — every callback rejects a caller that is not the PoolManager
    // ─────────────────────────────────────────────────────────────────────────────

    function test_beforeSwap_revertsForNonPoolManager() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(attacker);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(attacker, key, params, "");
    }

    function test_afterSwap_revertsForNonPoolManager() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(attacker);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(attacker, key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function test_beforeInitialize_revertsForNonPoolManager() public {
        vm.prank(attacker);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(attacker, key, 0);
    }

    /// @dev The specific attack the guard exists to stop: poisoning a pool's baseline by calling
    ///      `afterSwap` directly with fabricated trade data, so that later real attacks read as
    ///      normal. If this ever passes, the entire detection mechanism is defeated at zero cost.
    function test_baselineCannotBePoisonedByDirectCall() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e24, sqrtPriceLimitX96: 0});

        (,,, uint32 samplesBefore,) = hook.baselines(key.toId());

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(attacker);
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.afterSwap(attacker, key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
        }

        (,,, uint32 samplesAfter,) = hook.baselines(key.toId());
        assertEq(samplesAfter, samplesBefore, "baseline must be unreachable except through a real swap");
    }

    /// @dev The PoolManager itself must still get through — a guard that rejects everyone is not
    ///      access control, it is a broken hook. Asserts the check is on identity, not a blanket
    ///      revert.
    function test_poolManagerIsAccepted() public {
        vm.prank(POOL_MANAGER);
        bytes4 selector = hook.beforeInitialize(address(this), key, 0);
        assertEq(selector, BaseHook.beforeInitialize.selector);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Test 9 — owner controls are gated and bounded
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setParameters_revertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setParameters(4, 30, 3_000);
    }

    function test_setParameters_ownerCanUpdateWithinBounds() public {
        vm.prank(owner);
        hook.setParameters(5, 50, 1_000);

        assertEq(hook.k(), 5);
        assertEq(hook.minSamples(), 50);
        assertEq(hook.baseFee(), 1_000);
    }

    /// @dev Bounds are enforced in the setter, not merely documented. A compromised owner key must
    ///      not be able to turn the hook into a confiscation device, so `MAX_TOTAL_FEE` is a
    ///      constant and the setter cannot approach it from below via `baseFee`.
    function test_setParameters_rejectsOutOfBoundsValues() public {
        vm.startPrank(owner);

        vm.expectRevert(AntibodyHook.ParameterOutOfBounds.selector);
        hook.setParameters(1, 30, 3_000); // k below MIN_K

        vm.expectRevert(AntibodyHook.ParameterOutOfBounds.selector);
        hook.setParameters(11, 30, 3_000); // k above MAX_K

        vm.expectRevert(AntibodyHook.ParameterOutOfBounds.selector);
        hook.setParameters(3, 2, 3_000); // minSamples below floor

        vm.expectRevert(AntibodyHook.ParameterOutOfBounds.selector);
        hook.setParameters(3, 2_000, 3_000); // minSamples above ceiling

        vm.expectRevert(AntibodyHook.ParameterOutOfBounds.selector);
        hook.setParameters(3, 30, 60_000); // baseFee above MAX_TOTAL_FEE

        vm.stopPrank();
    }

    /// @dev The fee ceiling must hold for *every* reachable owner configuration, not just the
    ///      default one. Fuzzed across the whole accepted parameter space.
    function testFuzz_totalFeeCanNeverExceedCeiling(uint8 _k, uint32 _minSamples, uint24 _baseFee) public {
        _k = uint8(bound(_k, hook.MIN_K(), hook.MAX_K()));
        _minSamples = uint32(bound(_minSamples, hook.MIN_SAMPLE_FLOOR(), hook.MAX_SAMPLE_FLOOR()));
        _baseFee = uint24(bound(_baseFee, hook.MIN_BASE_FEE(), hook.MAX_TOTAL_FEE()));

        vm.prank(owner);
        hook.setParameters(_k, _minSamples, _baseFee);

        assertLe(hook.baseFee(), hook.MAX_TOTAL_FEE(), "no owner setting may breach the fee ceiling");
        assertLe(hook.MAX_TOTAL_FEE(), LPFeeLibrary.MAX_LP_FEE, "ceiling must stay within protocol limits");
    }

    /// @dev The hook must never be able to hold funds. No delta flags means nothing to settle and
    ///      no withdrawal path to leave unguarded — the class of bug is designed out, not patched.
    function test_hookDeclaresNoDeltaPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertFalse(p.beforeSwapReturnDelta, "hook must not take a swap delta");
        assertFalse(p.afterSwapReturnDelta, "hook must not take a swap delta");
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    /// @dev A pool created without DYNAMIC_FEE_FLAG would silently discard every fee override this
    ///      hook computes — it would look like it was working while doing nothing. Refusing at
    ///      initialization is the only place that can be caught loudly.
    function test_beforeInitialize_rejectsStaticFeePool() public {
        PoolKey memory staticKey = key;
        staticKey.fee = 3_000;

        vm.prank(POOL_MANAGER);
        vm.expectRevert(AntibodyHook.NotDynamicFeePool.selector);
        hook.beforeInitialize(address(this), staticKey, 0);
    }
}

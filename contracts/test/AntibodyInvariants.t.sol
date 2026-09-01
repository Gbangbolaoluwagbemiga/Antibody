// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
import {AntibodyHandler} from "./handlers/AntibodyHandler.sol";

import {AntibodyHook} from "../src/AntibodyHook.sol";
import {IAntibodySignal} from "../src/interfaces/IAntibodySignal.sol";

/// @notice Properties that must hold across every history the fuzzer can invent.
///
/// @dev The unit suite proves the hook behaves correctly in situations I constructed. These prove
///      it behaves correctly in situations nobody constructed — thousands of random orderings of
///      swaps, sandwiches, round trips and elapsed time across four pools and six actors.
///
///      Each property here is a claim made somewhere in the project's documentation. Stating them
///      in prose and asserting them under fuzzing are different things, and the difference is
///      exactly where this project has been caught out before.
contract AntibodyInvariantsTest is BaseTest {
    using EasyPosm for *;

    AntibodyHook internal hook;
    AntibodyHandler internal handler;

    Currency internal c0;
    Currency internal c1;

    PoolKey[] internal pools;
    address[] internal actors;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags ^ (0x8888 << 144));
        deployCodeTo("AntibodyHook.sol:AntibodyHook", abi.encode(poolManager, address(this)), hookAddress);
        hook = AntibodyHook(hookAddress);

        // Several pools on the same pair, so donor/inheritance paths are reachable.
        int24[4] memory spacings = [int24(10), int24(60), int24(200), int24(100)];
        for (uint256 i = 0; i < spacings.length; i++) pools.push(_pool(spacings[i]));

        for (uint256 i = 0; i < 6; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            _fund(a);
            actors.push(a);
        }

        vm.roll(1_000_000);

        handler = new AntibodyHandler(hook, swapRouter, pools, actors);
        targetContract(address(handler));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // The safety properties the whole design rests on
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev The fee ceiling is a constant precisely so it cannot be argued with. If any reachable
    ///      history produces a quote above it, the "this cannot become a confiscation device"
    ///      claim is false.
    function invariant_feeNeverExceedsTheCeiling() public view {
        assertLe(handler.maxFeeSeen(), hook.MAX_TOTAL_FEE(), "a quoted fee breached the ceiling");
    }

    /// @dev Every quote must be at least the base fee. A path that returns less would mean the
    ///      hook can be used to obtain a discount, which is a different product.
    function invariant_feeNeverFallsBelowBase() public view {
        for (uint256 p = 0; p < pools.length; p++) {
            for (uint256 a = 0; a < actors.length; a++) {
                (, uint24 fee,,) = hook.quote(pools[p].toId(), actors[a], true, 1 ether);
                assertGe(fee, hook.baseFee(), "a quote fell below the base fee");
            }
        }
    }

    /// @dev The benign-failure guarantee, which is what makes the hook ungriefable. If the fuzzer
    ///      can find a sequence where an ordinary swap reverts, "a false positive costs a fee, not
    ///      access" stops being true.
    function invariant_swapsDoNotRevert() public view {
        assertEq(handler.reverts(), 0, "a swap reverted - the no-block guarantee is broken");
    }

    /// @dev A pool below minSamples must publish no opinion at all, in every reachable state.
    function invariant_uncalibratedPoolsPublishNothing() public view {
        for (uint256 p = 0; p < pools.length; p++) {
            PoolId id = pools[p].toId();
            if (!hook.isCalibrated(id)) {
                assertEq(hook.currentThreshold(id), 0, "an uncalibrated pool published a threshold");
            }
        }
    }

    /// @dev Inheritance may only come from a pool that earned it. This is the property the Sybil
    ///      fix installed, and it has to hold no matter what order pools were created in.
    function invariant_vaccinatedPoolsAlwaysHaveAnOpinion() public view {
        for (uint256 p = 0; p < pools.length; p++) {
            PoolId id = pools[p].toId();
            if (hook.vaccinated(id)) {
                assertTrue(hook.isCalibrated(id), "a vaccinated pool has no usable baseline");
                assertGt(hook.currentThreshold(id), 0, "a vaccinated pool published nothing");
            }
        }
    }

    /// @dev Memory must remain memory. Any address whose record has aged past the window pays
    ///      exactly base fee for an ordinary trade — otherwise the mark is permanent, which is the
    ///      blacklist the decay exists to prevent.
    function invariant_expiredMemoryCostsNothing() public view {
        for (uint256 a = 0; a < actors.length; a++) {
            (uint32 exits, uint32 lastFlagged) = hook.immunity(actors[a]);
            if (exits == 0 || lastFlagged == 0) continue;
            if (block.number - lastFlagged < hook.IMMUNITY_WINDOW()) continue;

            for (uint256 p = 0; p < pools.length; p++) {
                (IAntibodySignal.Signal signal,,,) = hook.quote(pools[p].toId(), actors[a], true, 0.01 ether);
                assertTrue(
                    signal != IAntibodySignal.Signal.CrossPoolMemory,
                    "an expired record was still being charged"
                );
            }
        }
    }

    /// @dev Sanity on the campaign itself, checked once after it finishes rather than as an
    ///      invariant. An invariant is evaluated before the first call too, so asserting "work
    ///      happened" there fails on an empty run and says nothing about the run that follows.
    ///
    ///      This matters more than it looks: a fuzz campaign that never reaches the interesting
    ///      branches passes every property vacuously. The counts are the evidence that the passes
    ///      above mean something.
    ///
    ///      The threshold is per-run, not per-campaign. Handler state resets between runs, so the
    ///      counters here reflect one sequence of `depth` calls spread across four actions -- about
    ///      fifty successful ones at depth 64 -- rather than the thousands the campaign performs in
    ///      total. Calibrating this to the aggregate was wrong and made every run look empty.
    function afterInvariant() public view {
        uint256 total = handler.swapCalls() + handler.sandwichCalls() + handler.roundTripCalls();
        assertGt(total, 20, "this run never exercised the mechanism meaningfully");
        assertGt(handler.sandwichCalls(), 0, "no sandwich was ever completed in this run");
        assertGt(handler.roundTripCalls(), 0, "no round trip was ever completed in this run");
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
            500_000e18,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            ""
        );
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(c0)).mint(who, 100_000_000e18);
        MockERC20(Currency.unwrap(c1)).mint(who, 100_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
}

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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {AntibodyHook} from "../src/AntibodyHook.sol";
import {IAntibodySignal} from "../src/interfaces/IAntibodySignal.sol";

/// @notice Vaccination: a new pool inherits protection instead of starting defenceless.
///
/// @dev Cold-start is the most targetable hole in a learned-threshold design, and it is targetable
///      precisely *because* the design is documented. An attacker reads that the statistical
///      detector stays silent until `minSamples`, waits for a fresh pool, and works the window.
///      Refusing to have an opinion is the right call when there is genuinely nothing to base one
///      on — but a pool trading a pair that an established sibling has already characterised is not
///      in that position.
///
///      So a new pool inherits its opening baseline from the best-calibrated pool on the same token
///      pair. Protection before exposure, which is what a vaccine is.
///
///      Two honesty constraints shape the implementation:
///
///      1. Inheritance is only accepted from a pool that actually earned its baseline. A pool that
///         is itself uncalibrated has nothing to confer, and passing along an unearned opinion
///         would launder exactly the "subjective input" this project exists to remove.
///
///      2. The inherited state is marked. A vaccinated pool has an opinion it did not observe, and
///         a UI or integrator that cannot tell the difference is being misled. The EWMA then
///         replaces the priors with lived experience over roughly its own memory length — the
///         inheritance is a starting point, never a permanent verdict.
contract AntibodyVaccinationTest is BaseTest {
    using EasyPosm for *;
    using StateLibrary for IPoolManager;

    AntibodyHook internal hook;

    Currency internal c0;
    Currency internal c1;
    Currency internal other0;
    Currency internal other1;

    address internal owner = makeAddr("owner");
    address internal honest = makeAddr("honest");

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant TYPICAL = 1e18;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        (other0, other1) = deployCurrencyPair();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags ^ (0x6666 << 144));
        deployCodeTo("AntibodyHook.sol:AntibodyHook", abi.encode(poolManager, owner), hookAddress);
        hook = AntibodyHook(hookAddress);

        _fund(honest);
        vm.roll(2_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Baseline behaviour must not change when there is no sibling to learn from. A first pool
    ///      still earns its opinion the hard way.
    function test_firstPoolOfAPair_startsWithNoOpinion() public {
        PoolKey memory a = _pool(c0, c1, 60);

        assertFalse(hook.isCalibrated(a.toId()), "nothing to inherit from");
        assertEq(hook.currentThreshold(a.toId()), 0);
        assertFalse(hook.vaccinated(a.toId()));
    }

    /// @dev The headline. A pool created after a sibling has characterised the pair is protected
    ///      from its very first swap.
    function test_newPool_inheritsProtectionFromCalibratedSibling() public {
        PoolKey memory a = _pool(c0, c1, 60);
        _calibrate(a);
        assertTrue(hook.isCalibrated(a.toId()));
        uint256 donorThreshold = hook.currentThreshold(a.toId());

        PoolKey memory b = _pool(c0, c1, 10); // same pair, brand new
        PoolId idB = b.toId();

        assertTrue(hook.vaccinated(idB), "the new pool must be marked as protected by inheritance");
        assertTrue(hook.isCalibrated(idB), "and it must have an opinion immediately");
        assertEq(hook.currentThreshold(idB), donorThreshold, "which is the sibling's, exactly");

        // And it actually defends: an oversized trade is priced on the new pool's first swap.
        (IAntibodySignal.Signal signal, uint24 fee,,) = hook.quote(idB, honest, true, TYPICAL * 400);
        assertEq(uint8(signal), uint8(IAntibodySignal.Signal.SizeAnomaly), "protected from swap one");
        assertGt(fee, hook.baseFee());
    }

    /// @dev An uncalibrated pool has nothing to give. Passing on an unearned opinion would launder
    ///      a guess into something that looks like evidence.
    function test_uncalibratedSibling_confersNothing() public {
        PoolKey memory a = _pool(c0, c1, 60);
        _swap(a, honest, true, TYPICAL); // one swap: nowhere near minSamples

        PoolKey memory b = _pool(c0, c1, 10);

        assertFalse(hook.vaccinated(b.toId()), "an uncalibrated pool cannot vaccinate");
        assertEq(hook.currentThreshold(b.toId()), 0);
    }

    /// @dev Immunity is pair-specific. A baseline learned on one token pair says nothing about
    ///      another, and inheriting across pairs would be transferring a number with no meaning.
    function test_inheritance_doesNotCrossTokenPairs() public {
        PoolKey memory a = _pool(c0, c1, 60);
        _calibrate(a);

        PoolKey memory unrelated = _pool(other0, other1, 60);

        assertFalse(hook.vaccinated(unrelated.toId()), "a different pair confers nothing");
        assertEq(hook.currentThreshold(unrelated.toId()), 0);
    }

    /// @dev The inheritance is a starting point, not a verdict. A vaccinated pool whose own flow
    ///      differs must converge on what it actually sees.
    function test_ownExperienceReplacesTheInheritedPriors() public {
        PoolKey memory a = _pool(c0, c1, 60);
        _calibrate(a); // characterised by TYPICAL-sized flow

        PoolKey memory b = _pool(c0, c1, 10);
        uint256 inherited = hook.currentThreshold(b.toId());

        // Pool B's real flow is an order of magnitude larger.
        for (uint256 i = 0; i < 40; i++) {
            vm.roll(block.number + 1);
            _swap(b, honest, true, TYPICAL * 10);
        }

        uint256 earned = hook.currentThreshold(b.toId());
        assertGt(earned, inherited, "the pool's own observations must take over");
    }

    /// @dev Vaccination must not become a back door around the fee ceiling or the no-block rule.
    function testFuzz_vaccinatedPool_staysWithinTheSameBounds(uint256 amount) public {
        PoolKey memory a = _pool(c0, c1, 60);
        _calibrate(a);
        PoolKey memory b = _pool(c0, c1, 10);

        amount = bound(amount, 0.001 ether, 5_000 ether);
        (, uint24 fee,,) = hook.quote(b.toId(), honest, true, amount);

        assertLe(fee, hook.MAX_TOTAL_FEE());
        assertGe(fee, hook.baseFee());
    }

    // ─────────────────────────────────────────────────────────────────────────────

    function _pool(Currency a, Currency b, int24 tickSpacing) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: a,
            currency1: b,
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
        for (uint256 i = 0; i < 4; i++) {
            Currency c = [c0, c1, other0, other1][i];
            MockERC20(Currency.unwrap(c)).mint(who, 5_000_000e18);
            vm.prank(who);
            MockERC20(Currency.unwrap(c)).approve(address(swapRouter), type(uint256).max);
        }
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
}

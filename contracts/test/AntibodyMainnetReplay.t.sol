// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {AntibodyHook} from "../src/AntibodyHook.sol";
import {IAntibodySignal} from "../src/interfaces/IAntibodySignal.sol";

/// @notice Replay of real sandwich attacks taken off Ethereum mainnet.
///
/// @dev Every attack elsewhere in this repo was staged by me, against a detector I designed. The
///      obvious objection is that of course it catches those. This replays shapes I did not author.
///
///      `research/scan_sandwiches.py` walks live Uniswap v3 blocks and identifies sandwiches by
///      their mechanical signature — an address swaps, a different address swaps the same way, the
///      position is closed in reverse — resolving true senders from each block's transactions
///      because a Swap log's `sender` is the router, not the person. The fixture here is its output.
///
///      Deliberately NOT modelled: profit. Those pools are v2/v3 with static fees and different
///      liquidity mechanics, so any "Antibody would have taken $X" figure would be a guess dressed
///      as evidence. Detection is a classification question and answerable honestly: given this
///      exact ordering of trader and direction, does the detector fire, and which one?
///
///      The headline result is uncomfortable and is the reason this file exists. Across 610 live
///      blocks containing swaps, all 25 sandwich-shaped events split entry and exit across
///      different addresses. Not one was same-origin. `SandwichExit` — the maximum penalty, and
///      the signal every demo in this project is built on — would not have fired on a single one.
///      `BlockReversal` catches all of them, which is why it was repriced from half the span to
///      three quarters.
contract AntibodyMainnetReplayTest is BaseTest {
    using EasyPosm for *;
    using stdJson for string;

    AntibodyHook internal hook;
    PoolKey internal pool;

    Currency internal c0;
    Currency internal c1;

    address internal entryActor = makeAddr("mainnet-entry");
    address internal exitActor = makeAddr("mainnet-exit");
    address internal victimActor = makeAddr("mainnet-victim");
    address internal calibrator = makeAddr("calibrator");

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant TYPICAL = 1e18;

    string internal fixture;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags ^ (0x9999 << 144));
        deployCodeTo("AntibodyHook.sol:AntibodyHook", abi.encode(poolManager, address(this)), hookAddress);
        hook = AntibodyHook(hookAddress);

        pool = _pool(60);
        _fund(entryActor);
        _fund(exitActor);
        _fund(victimActor);
        _fund(calibrator);

        vm.roll(1_000_000);
        _calibrate();

        fixture = vm.readFile("test/fixtures/mainnet_sandwiches.json");
    }

    /// @dev The measurement. Replays every captured sequence and reports which detector fired.
    function test_replayRealMainnetSandwiches() public {
        uint256 count = fixture.readUint(".sandwichCount");
        assertGt(count, 0, "fixture is empty");

        uint256 caughtBySandwichExit;
        uint256 caughtByBlockReversal;
        uint256 missed;

        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".sequences[", vm.toString(i), "]");
            bool sameOrigin = fixture.readBool(string.concat(base, ".sameOrigin"));
            bool entryZeroForOne = fixture.readBool(string.concat(base, ".entryZeroForOne"));

            // Fresh block per sequence, so records from the previous replay cannot leak in.
            vm.roll(block.number + 50);

            address closer = sameOrigin ? entryActor : exitActor;

            _swap(entryActor, entryZeroForOne, TYPICAL * 2);
            _swap(victimActor, entryZeroForOne, TYPICAL); // the trade being sandwiched

            vm.recordLogs();
            _swap(closer, !entryZeroForOne, TYPICAL * 2);

            IAntibodySignal.Signal signal = _lastSignal();
            if (signal == IAntibodySignal.Signal.SandwichExit) caughtBySandwichExit++;
            else if (signal == IAntibodySignal.Signal.BlockReversal) caughtByBlockReversal++;
            else missed++;
        }

        emit log_named_uint("sequences replayed", count);
        emit log_named_uint("caught by SandwichExit", caughtBySandwichExit);
        emit log_named_uint("caught by BlockReversal", caughtByBlockReversal);
        emit log_named_uint("missed entirely", missed);

        // The claim that matters: every real sandwich in the sample is caught by something.
        assertEq(missed, 0, "a real mainnet sandwich went undetected");
        assertEq(
            caughtBySandwichExit + caughtByBlockReversal,
            count,
            "every replayed sequence must be classified"
        );
    }

    /// @dev The finding, asserted rather than only written down. If a future change makes
    ///      same-origin the dominant observed shape, this fails and the docs need revisiting.
    function test_theMeasuredShapeIsMultiAddress() public view {
        uint256 same = fixture.readUint(".sameOrigin");
        uint256 multi = fixture.readUint(".multiOrigin");

        assertEq(same, 0, "sample contained a same-origin sandwich");
        assertGt(multi, 0, "sample contained no multi-address sandwich");
    }

    /// @dev The negative side of the measurement. Most blocks with swap activity contain no
    ///      sandwich shape at all, which is what makes the detector specific rather than constant.
    function test_mostBlocksWithActivityHaveNoSandwich() public view {
        uint256 withSwaps = fixture.readUint(".blocksWithSwaps");
        uint256 without = fixture.readUint(".blocksWithoutSandwich");

        assertGt(without * 100, withSwaps * 90, "the shape should be rare, not routine");
    }

    // ─────────────────────────────────────────────────────────────────────────────

    function _lastSignal() internal returns (IAntibodySignal.Signal) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics.length > 0 && logs[i - 1].topics[0] == IAntibodySignal.ToxicFlowDetected.selector) {
                (uint8 raw,,,) = abi.decode(logs[i - 1].data, (uint8, uint256, uint256, uint24));
                return IAntibodySignal.Signal(raw);
            }
        }
        return IAntibodySignal.Signal.None;
    }

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
        MockERC20(Currency.unwrap(c0)).mint(who, 50_000_000e18);
        MockERC20(Currency.unwrap(c1)).mint(who, 50_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address who, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(who, who);
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, pool, "", who, block.timestamp + 1);
    }

    function _calibrate() internal {
        for (uint256 i = 0; i < hook.minSamples() + 3; i++) {
            vm.roll(block.number + 1);
            _swap(calibrator, true, TYPICAL);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {AntibodyHook} from "../src/AntibodyHook.sol";
import {IAntibodySignal} from "../src/interfaces/IAntibodySignal.sol";

/// @notice How often the detector fires on ORDINARY mainnet blocks.
///
/// @dev AntibodyMainnetReplay answers "does it catch real attacks" — 25 of 25. That is recall, and
///      recall on its own is worth nothing: a detector that fires on every swap also scores 25 of
///      25. The question that went unasked for six deployments is precision.
///
///      It mattered here more than usual, because the condition originally shipped was:
///
///          pl.lastBlock == block.number && pl.lastZeroForOne != zeroForOne && pl.lastTrader != trader
///
///      which describes a sandwich exit and also describes two arbitrageurs crossing in a busy
///      block. Replaying 321 real mainnet blocks through it:
///
///          as shipped     recall 23/23 (100%)   fired on 35 of 117 ordinary blocks   precision  40%
///          victim-gated   recall 18/23  (78%)   fired on  0 of 117 ordinary blocks   precision 100%
///
///      Roughly three fifths of everything it flagged was innocent. That is the same defect as the
///      23-of-23 false positives on Unichain Sepolia, wearing a different variable name.
///
///      The gate costs 5 of 23 in recall and that is a deliberate trade. Those 5 are lost to the
///      O(1) state a hook can afford: an offline pass with the whole block in view keeps all 23 at
///      zero false positives, but afterSwap sees one swap and two storage words. Given the choice,
///      precision wins — a false positive overcharges an innocent trader, which is exactly the
///      "coarse rule engine driven by subjective inputs" criticism this design exists to answer.
///
///      Blocks replay against a real pool through the real hook, one fresh block number each, with
///      trader indices preserved from mainnet so that who-is-distinct-from-whom survives.
contract AntibodyPrecisionTest is BaseTest {
    using stdJson for string;
    using EasyPosm for IPositionManager;

    Currency internal c0;
    Currency internal c1;
    AntibodyHook internal hook;
    PoolKey internal pool;
    string internal fixture;

    uint256 internal constant ACTORS = 9; // maxDistinctTradersInABlock, from the fixture
    address[ACTORS] internal actors;
    uint256 internal constant TYPICAL = 1e18;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags ^ (0x7777 << 144));
        deployCodeTo("AntibodyHook.sol:AntibodyHook", abi.encode(poolManager, address(this)), hookAddress);
        hook = AntibodyHook(hookAddress);

        pool = _pool(60);
        for (uint256 i = 0; i < ACTORS; i++) {
            actors[i] = address(uint160(0xA0000 + i));
            _fund(actors[i]);
        }
        vm.roll(2_000_000);
        _calibrate();

        fixture = vm.readFile("test/fixtures/mainnet_precision.json");
    }

    /// The measurement this file exists for: the gated detector must not fire on ordinary blocks.
    function test_detectorDoesNotFireOnOrdinaryMainnetBlocks() public {
        uint256 n = fixture.readUint(".blocksKept");
        uint256 firedOnOrdinary;
        uint256 caughtSandwich;
        uint256 ordinary;
        uint256 sandwich;

        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".blocks[", vm.toString(i), "]");
            bool isSandwich = fixture.readBool(string.concat(base, ".sandwich"));
            uint256[] memory t = fixture.readUintArray(string.concat(base, ".t"));
            uint256[] memory d = fixture.readUintArray(string.concat(base, ".d"));

            // A fresh block per replay, so in-block state from the previous one cannot leak in.
            vm.roll(block.number + 10);

            vm.recordLogs();
            for (uint256 j = 0; j < t.length; j++) {
                _swap(actors[t[j]], d[j] == 1, TYPICAL);
            }
            bool fired = _sawStructuralSignal();

            if (isSandwich) {
                sandwich++;
                if (fired) caughtSandwich++;
            } else {
                ordinary++;
                if (fired) firedOnOrdinary++;
            }
        }

        emit log_named_uint("ordinary blocks replayed", ordinary);
        emit log_named_uint("  ...the detector fired on", firedOnOrdinary);
        emit log_named_uint("sandwich blocks replayed", sandwich);
        emit log_named_uint("  ...the detector caught", caughtSandwich);

        // The property. Zero false positives across every ordinary mainnet block in the sample.
        assertEq(firedOnOrdinary, 0, "the detector fired on a block with no sandwich in it");

        // Recall is asserted as a floor rather than a fixed number: the gate is known to cost some
        // detections to O(1) state, and pinning the exact figure would turn an honest limitation
        // into a brittle test. Dropping below three quarters means something regressed.
        assertGe(caughtSandwich * 4, sandwich * 3, "recall fell below 75% of sandwich blocks");
    }

    function _sawStructuralSignal() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == IAntibodySignal.ToxicFlowDetected.selector) {
                (uint8 raw,,,) = abi.decode(logs[i].data, (uint8, uint256, uint256, uint24));
                IAntibodySignal.Signal s = IAntibodySignal.Signal(raw);
                // Only the structural verdicts count here. SizeAnomaly is a size flag rather than an
                // accusation, and it is the statistical signal's job to fire on unusual size.
                if (s == IAntibodySignal.Signal.SandwichExit || s == IAntibodySignal.Signal.BlockReversal) {
                    return true;
                }
            }
        }
        return false;
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

    function _calibrate() internal {
        for (uint256 i = 0; i < hook.minSamples() + 3; i++) {
            vm.roll(block.number + 1);
            _swap(actors[0], true, TYPICAL);
        }
    }

    function _swap(address who, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(who, who);
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, pool, "", who, block.timestamp + 1);
    }
}

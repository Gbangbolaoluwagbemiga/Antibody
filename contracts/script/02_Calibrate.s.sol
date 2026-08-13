// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {AntibodyHook} from "../src/AntibodyHook.sol";

/// @notice Feeds the live pool ordinary, unremarkable flow until its statistical detector
///         activates.
///
/// @dev This step is the demo's most important one and the easiest to mistake for filler. Until a
///      pool has observed `minSamples` swaps, AntibodyHook publishes no threshold at all — it
///      refuses to have an opinion it hasn't earned. Running this is what turns the abstract claim
///      ("the baseline is learned, not configured") into something a judge can watch happen: the
///      threshold is literally absent, then it exists, then it tracks.
///
///      Every swap here also emits `BaselineUpdated`, which is the event series the demo UI charts.
contract CalibrateScript is BaseScript {
    uint256 internal constant TYPICAL_SWAP = 0.1 ether;

    function run() external {
        requireTokens();

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hookContract
        });
        PoolId poolId = poolKey.toId();
        AntibodyHook hook = AntibodyHook(address(hookContract));

        uint32 target = hook.minSamples() + 5;
        (,,, uint32 observed,) = hook.baselines(poolId);

        console.log("Calibrating pool");
        console.log("  samples observed:", observed);
        console.log("  samples required:", target);

        if (observed >= target) {
            console.log("  already calibrated; threshold:", hook.currentThreshold(poolId));
            return;
        }

        vm.startBroadcast();

        IERC20(address(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(address(token1)).approve(address(swapRouter), type(uint256).max);

        // Alternating direction, constant size: a calm regime. The baseline should settle on a
        // tight band, which is what makes the later attack stand out against it.
        for (uint32 i = observed; i < target; i++) {
            swapRouter.swapExactTokensForTokens(
                TYPICAL_SWAP, 0, i % 2 == 0, poolKey, "", deployerAddress, block.timestamp + 3600
            );
        }

        vm.stopBroadcast();

        console.log("Calibration submitted. Re-run 04_Inspect to read the resulting threshold.");
    }
}

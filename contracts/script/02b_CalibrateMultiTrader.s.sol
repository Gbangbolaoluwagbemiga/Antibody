// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {AntibodyHook} from "../src/AntibodyHook.sol";

/// @notice Calibrate a pool with genuinely distinct traders, so it can qualify as a donor.
///
/// @dev The single-address calibration script cannot produce an eligible donor any more, and that
///      is the point of the eligibility gate rather than an inconvenience to route around. An
///      adversarial test showed that "twenty swaps happened" was satisfiable by one address trading
///      against itself, which let an attacker author the baseline every later pool on the pair
///      would inherit.
///
///      So the honest path costs what the gate says it costs: several funded addresses, real
///      swaps from each, and `MIN_DONOR_AGE` blocks of existence before the pool can confer
///      anything. This script does the first two; only time does the third.
contract CalibrateMultiTraderScript is BaseScript {
    uint256 internal constant SWAP_SIZE = 0.1 ether;
    uint256 internal constant SWAPS_EACH = 5;
    uint256 internal constant GAS_FUNDING = 0.003 ether;
    uint256 internal constant TOKEN_FUNDING = 500_000 ether;

    function run() external {
        requireTokens();

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60)))),
            hooks: hookContract
        });
        PoolId poolId = poolKey.toId();
        AntibodyHook hook = AntibodyHook(address(hookContract));

        uint256 traders = vm.envOr("CALIBRATOR_COUNT", uint256(5));

        (uint32 breadth,) = hook.poolQuality(poolId);
        (,,, uint32 samples,) = hook.baselines(poolId);
        console.log("before: samples", samples, "distinct traders", breadth);

        // Fund every calibrator from the deployer in one broadcast.
        vm.startBroadcast();
        for (uint256 i = 1; i <= traders; i++) {
            address who = vm.envAddress(string.concat("CALIBRATOR_", vm.toString(i)));
            if (who.balance < GAS_FUNDING) payable(who).transfer(GAS_FUNDING);
            MockERC20(address(token0)).mint(who, TOKEN_FUNDING);
            MockERC20(address(token1)).mint(who, TOKEN_FUNDING);
        }
        vm.stopBroadcast();

        // Then each trades under its own key, which is what makes them distinct to the hook.
        for (uint256 i = 1; i <= traders; i++) {
            uint256 pk = vm.envUint(string.concat("CALIBRATOR_", vm.toString(i), "_KEY"));
            address who = vm.envAddress(string.concat("CALIBRATOR_", vm.toString(i)));

            vm.startBroadcast(pk);
            IERC20(address(token0)).approve(address(swapRouter), type(uint256).max);
            IERC20(address(token1)).approve(address(swapRouter), type(uint256).max);
            for (uint256 j = 0; j < SWAPS_EACH; j++) {
                swapRouter.swapExactTokensForTokens(
                    SWAP_SIZE, 0, true, poolKey, "", who, block.timestamp + 3600
                );
            }
            vm.stopBroadcast();
        }

        console.log("submitted", traders * SWAPS_EACH, "swaps across", traders);
        console.log("Donor also needs MIN_DONOR_AGE blocks:", hook.MIN_DONOR_AGE());
    }
}

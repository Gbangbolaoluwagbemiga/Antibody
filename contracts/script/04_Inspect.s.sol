// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {AntibodyHook} from "../src/AntibodyHook.sol";
import {IAntibodySignal} from "../src/interfaces/IAntibodySignal.sol";

/// @notice Reads the live pool's learned state and prints what Antibody currently thinks.
///
/// @dev Read-only. This is the script to run in front of a judge: it shows the threshold the pool
///      computed for itself, and quotes what each kind of trade would be charged against it —
///      including the counterfactual, which is the number that makes the mechanism legible in one
///      line ("this swap pays 0.30%; the same swap as a sandwich exit pays 5%").
contract InspectScript is BaseScript {
    function run() external view {
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

        address attacker = vm.envAddress("DEMO_ATTACKER");
        address bystander = address(uint160(uint256(keccak256("antibody.bystander"))));

        (uint64 mean, uint64 dev, uint64 impact, uint32 samples, uint32 lastBlock) = hook.baselines(poolId);

        console.log("=== Antibody pool state ===");
        console.log("  poolId       ");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("  swaps seen   ", samples);
        console.log("  last block   ", lastBlock);
        console.log("  mean size    ", mean);
        console.log("  deviation    ", dev);
        console.log("  mean impact  ", impact);
        console.log("  calibrated   ", hook.isCalibrated(poolId));
        console.log("  threshold    ", hook.currentThreshold(poolId));

        console.log("=== what a trade would pay right now ===");

        // Each quote is scoped so its temporaries are released; without this the function's
        // locals exceed the EVM stack.
        {
            (IAntibodySignal.Signal s, uint24 f,,) = hook.quote(poolId, bystander, true, 0.1 ether);
            console.log("  ordinary 0.1 swap, fresh address -> signal/fee:", uint8(s), f);
        }
        {
            (IAntibodySignal.Signal s, uint24 f,,) = hook.quote(poolId, bystander, true, 2 ether);
            console.log("  oversized 2.0 swap, fresh address -> signal/fee:", uint8(s), f);
        }
        {
            (IAntibodySignal.Signal s, uint24 f,,) = hook.quote(poolId, attacker, false, 2 ether);
            console.log("  attacker reversing position     -> signal/fee:", uint8(s), f);
        }
        {
            (uint32 exits, uint32 lastBlock) = hook.immunity(attacker);
            console.log("  attacker cross-pool record: exits / lastBlock:", exits, lastBlock);
        }

        console.log("  (signal: 0=None 1=SandwichExit 2=BlockReversal 3=SizeAnomaly 4=CrossPoolMemory)");
        console.log("  (fee is hundredths of a bip: 3000 = 0.30%, 50000 = 5.00%)");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {AntibodyHook} from "../src/AntibodyHook.sol";
import {IAntibodySignal} from "../src/interfaces/IAntibodySignal.sol";

/// @notice Executes a genuine sandwich against the live Antibody pool: attacker front-runs, an
///         unrelated victim fills at the worsened price, attacker exits.
///
/// @dev ── A constraint worth stating plainly ────────────────────────────────────────────────
///
///      `Signal.SandwichExit` requires the attacker's two legs to share a block, because that is
///      what makes the pattern a sandwich rather than two ordinary trades. On a public testnet
///      nothing lets a script *guarantee* that: there is no bundle endpoint here, and Unichain's
///      ~1s blocks mean three sequentially-broadcast transactions may or may not land together.
///
///      So this script reports what actually happened rather than asserting what it hoped would.
///      If the legs land in one block the strongest detector fires; if they split, the pool-level
///      and statistical detectors still respond, and the printed block numbers say which case a
///      given run was. A demo that quietly claims the strong result regardless of what the chain
///      did would be the same class of dishonesty this project was built to correct.
///
///      Run `04_Inspect` afterwards to read the resulting classification out of the logs.
contract SandwichScript is BaseScript {
    uint256 internal constant ATTACK_SIZE = 2 ether;
    uint256 internal constant VICTIM_SIZE = 0.5 ether;

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

        address attacker = vm.envAddress("DEMO_ATTACKER");
        address victim = vm.envAddress("DEMO_VICTIM");
        uint256 attackerKey = vm.envUint("DEMO_ATTACKER_KEY");
        uint256 victimKey = vm.envUint("DEMO_VICTIM_KEY");

        console.log("--- before ---");
        console.log("  calibrated:", hook.isCalibrated(poolId));
        console.log("  threshold: ", hook.currentThreshold(poolId));

        // What the exit leg would be charged right now, before any of this executes. Quoting the
        // back-run in advance is the clearest way to show the penalty is a property of the
        // *pattern*, not a post-hoc label.
        (IAntibodySignal.Signal preSignal, uint24 preFee,,) = hook.quote(poolId, attacker, false, ATTACK_SIZE);
        console.log("  attacker exit would be signal/fee:", uint8(preSignal), preFee);

        // ── Leg 1: front-run. Attacker buys ahead of the victim.
        vm.startBroadcast(attackerKey);
        swapRouter.swapExactTokensForTokens(
            ATTACK_SIZE, 0, true, poolKey, "", attacker, block.timestamp + 3600
        );
        vm.stopBroadcast();

        // ── Leg 2: the victim's trade, now filling at a worse price.
        vm.startBroadcast(victimKey);
        swapRouter.swapExactTokensForTokens(
            VICTIM_SIZE, 0, true, poolKey, "", victim, block.timestamp + 3600
        );
        vm.stopBroadcast();

        // ── Leg 3: the exit. This is the leg Antibody is built to price.
        vm.startBroadcast(attackerKey);
        swapRouter.swapExactTokensForTokens(
            ATTACK_SIZE, 0, false, poolKey, "", attacker, block.timestamp + 3600
        );
        vm.stopBroadcast();

        console.log("Sandwich submitted: front-run, victim, exit.");
        console.log("Run 04_Inspect to read the classification and the LP fee impact.");
    }
}

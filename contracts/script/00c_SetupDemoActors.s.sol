// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseScript} from "./base/BaseScript.sol";

/// @notice Funds the demo attacker and victim with gas and tokens, and sets their router
///         approvals, so the live sandwich script can run without any manual setup.
///
/// @dev Separate EOAs matter here rather than being cosmetic: AntibodyHook keys its structural
///      detectors on `tx.origin`, so a demo where the attacker and the victim share an address
///      would not exercise the detection path the submission is actually claiming.
contract SetupDemoActorsScript is BaseScript {
    uint256 internal constant GAS_FUNDING = 0.005 ether;
    uint256 internal constant TOKEN_FUNDING = 1_000_000 ether;

    function run() external {
        requireTokens();

        address attacker = vm.envAddress("DEMO_ATTACKER");
        address victim = vm.envAddress("DEMO_VICTIM");
        uint256 attackerKey = vm.envUint("DEMO_ATTACKER_KEY");
        uint256 victimKey = vm.envUint("DEMO_VICTIM_KEY");

        // Gas and tokens, from the deployer.
        vm.startBroadcast();
        if (attacker.balance < GAS_FUNDING) payable(attacker).transfer(GAS_FUNDING);
        if (victim.balance < GAS_FUNDING) payable(victim).transfer(GAS_FUNDING);

        MockERC20(address(token0)).mint(attacker, TOKEN_FUNDING);
        MockERC20(address(token1)).mint(attacker, TOKEN_FUNDING);
        MockERC20(address(token0)).mint(victim, TOKEN_FUNDING);
        MockERC20(address(token1)).mint(victim, TOKEN_FUNDING);
        vm.stopBroadcast();

        // Approvals must be signed by each actor, so each gets its own broadcast context.
        vm.startBroadcast(attackerKey);
        MockERC20(address(token0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(address(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(victimKey);
        MockERC20(address(token0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(address(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopBroadcast();

        console.log("Demo actors ready.");
        console.log("  attacker:", attacker);
        console.log("  victim:  ", victim);
    }
}

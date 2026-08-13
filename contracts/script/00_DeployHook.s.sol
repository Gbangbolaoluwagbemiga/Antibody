// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {AntibodyHook} from "../src/AntibodyHook.sol";

/// @notice Mines a salt producing a hook address whose low bits encode the required permissions,
///         then deploys AntibodyHook via CREATE2.
///
/// @dev The flags below MUST match `AntibodyHook.getHookPermissions()` exactly. A mismatch is the
///      single most common cause of a v4 hook deployment reverting, and the failure mode is
///      opaque, so it is asserted twice: once by the miner, once by the address check after deploy.
contract DeployHookScript is BaseScript {
    function run() public {
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Hook owner. Falls back to the deployer rather than being hardcoded anywhere.
        address owner = vm.envOr("HOOK_OWNER", deployerAddress);

        bytes memory constructorArgs = abi.encode(poolManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(AntibodyHook).creationCode, constructorArgs);

        vm.startBroadcast();
        AntibodyHook hook = new AntibodyHook{salt: salt}(poolManager, owner);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: hook address mismatch");

        console.log("AntibodyHook deployed:", address(hook));
        console.log("  owner:      ", owner);
        console.log("  poolManager:", address(poolManager));
        console.log("  chainId:    ", block.chainid);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Deploys the two demo tokens the Antibody pool trades, and mints a working balance to
///         the deployer plus any additional actors the demo needs.
///
/// @dev Testnet-only scaffolding. These are unrestricted-mint mock tokens and exist purely so the
///      demo has something to trade; nothing in the hook depends on them.
///
///      Prints the two addresses in canonical (sorted) order, because Uniswap orders a pool's
///      currencies by address and the pool scripts expect TOKEN0 < TOKEN1.
contract DeployTestTokensScript is Script {
    uint256 internal constant MINT_AMOUNT = 10_000_000 ether;

    function run() external {
        vm.startBroadcast();

        MockERC20 tokenA = new MockERC20("Antibody Demo A", "ABDA", 18);
        MockERC20 tokenB = new MockERC20("Antibody Demo B", "ABDB", 18);

        address deployer = msg.sender;
        tokenA.mint(deployer, MINT_AMOUNT);
        tokenB.mint(deployer, MINT_AMOUNT);

        // Fund the demo actors so the attacker script can run without a separate funding step.
        address attacker = vm.envOr("DEMO_ATTACKER", address(0));
        address victim = vm.envOr("DEMO_VICTIM", address(0));

        if (attacker != address(0)) {
            tokenA.mint(attacker, MINT_AMOUNT);
            tokenB.mint(attacker, MINT_AMOUNT);
        }
        if (victim != address(0)) {
            tokenA.mint(victim, MINT_AMOUNT);
            tokenB.mint(victim, MINT_AMOUNT);
        }

        vm.stopBroadcast();

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        console.log("Test tokens deployed. Add to .env:");
        console.log("  TOKEN0=", token0);
        console.log("  TOKEN1=", token1);
    }
}

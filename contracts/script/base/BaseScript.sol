// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {Deployers} from "test/utils/Deployers.sol";

/// @notice Shared configuration between scripts
contract BaseScript is Script, Deployers {
    address immutable deployerAddress;

    /////////////////////////////////////
    // --- Deployment configuration ---
    //
    // Read from the environment, never hardcoded. Every address that differs between local anvil,
    // Unichain Sepolia, and any future target belongs in `.env` — see `.env.example`. Baking a
    // testnet address into a committed source file is how a deploy script silently targets the
    // wrong chain.
    /////////////////////////////////////
    IERC20 internal immutable token0;
    IERC20 internal immutable token1;
    IHooks internal immutable hookContract;
    /////////////////////////////////////

    Currency immutable currency0;
    Currency immutable currency1;

    constructor() {
        // Make sure artifacts are available, either deploy or configure.
        deployArtifacts();

        deployerAddress = getDeployer();

        // Optional at this layer. Deployment is ordered — hook, then tokens, then pool — so the
        // early scripts must not be blocked on configuration that only the later ones need.
        // Scripts that genuinely require these call `requireTokens()`, which fails loudly and
        // says which variable is missing.
        token0 = IERC20(vm.envOr("TOKEN0", address(0)));
        token1 = IERC20(vm.envOr("TOKEN1", address(0)));

        // Unset before the hook exists — 00_DeployHook does not need it, the later scripts do.
        hookContract = IHooks(vm.envOr("HOOK_ADDRESS", address(0)));

        (currency0, currency1) = getCurrencies();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");

        vm.label(address(token0), "Currency0");
        vm.label(address(token1), "Currency1");

        vm.label(address(hookContract), "HookContract");
    }

    function _etch(address target, bytes memory bytecode) internal override {
        if (block.chainid == 31337) {
            vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '",', '"', vm.toString(bytecode), '"]'));
        } else {
            revert("Unsupported etch on this network");
        }
    }

    /// @notice Assert the pool tokens are configured. Call this at the top of any script that
    ///         touches a pool, so a missing variable surfaces as a clear message rather than an
    ///         opaque revert deep inside a swap.
    function requireTokens() internal view {
        require(address(token0) != address(0), "BaseScript: TOKEN0 not set in .env");
        require(address(token1) != address(0), "BaseScript: TOKEN1 not set in .env");
    }

    function getCurrencies() internal view returns (Currency, Currency) {
        // Both unset is the legitimate pre-token state; both set to the same address is a mistake.
        if (address(token0) == address(0) && address(token1) == address(0)) {
            return (Currency.wrap(address(0)), Currency.wrap(address(0)));
        }
        require(address(token0) != address(token1), "BaseScript: TOKEN0 and TOKEN1 must differ");

        if (token0 < token1) {
            return (Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        } else {
            return (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
        }
    }

    function getDeployer() internal returns (address) {
        address[] memory wallets = vm.getWallets();

        if (wallets.length > 0) {
            return wallets[0];
        } else {
            return msg.sender;
        }
    }
}

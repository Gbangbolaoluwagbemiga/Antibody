// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {AntibodyHook} from "../../src/AntibodyHook.sol";

/// @notice Drives the hook through random sequences so invariants are tested against histories
///         nobody designed.
///
/// @dev Every unit test in this repo asserts something about a situation I constructed. That is
///      exactly the assurance that failed twice on this project: the calibration-contamination bug
///      and the Sybil donor hole both survived a passing suite because no test I wrote happened to
///      build the shape that exposed them.
///
///      A handler does not have that limitation. It performs bounded-random swaps, sandwiches and
///      round trips across several pools and actors, and the invariants have to hold across every
///      ordering the fuzzer invents — including the ones I would never have thought to write down.
contract AntibodyHandler is CommonBase, StdCheats, StdUtils {
    AntibodyHook public immutable hook;
    IUniswapV4Router04 public immutable router;

    PoolKey[] public pools;
    address[] public actors;

    // Coverage counters — a fuzz run that never reaches the interesting branches is a run that
    // proves nothing, so the suite reports how often each path was actually exercised.
    uint256 public swapCalls;
    uint256 public sandwichCalls;
    uint256 public roundTripCalls;
    uint256 public reverts;

    /// @dev Highest fee any swap has been quoted across the entire run. Checked against the
    ///      ceiling by the invariant rather than trusted.
    uint24 public maxFeeSeen;

    constructor(AntibodyHook _hook, IUniswapV4Router04 _router, PoolKey[] memory _pools, address[] memory _actors) {
        hook = _hook;
        router = _router;
        for (uint256 i = 0; i < _pools.length; i++) pools.push(_pools[i]);
        for (uint256 i = 0; i < _actors.length; i++) actors.push(_actors[i]);
    }

    function _pool(uint256 seed) internal view returns (PoolKey memory) {
        return pools[bound(seed, 0, pools.length - 1)];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _record(PoolKey memory key, address who, bool zeroForOne, uint256 amount) internal {
        (, uint24 fee,,) = hook.quote(key.toId(), who, zeroForOne, amount);
        if (fee > maxFeeSeen) maxFeeSeen = fee;
    }

    /// @notice An ordinary swap of arbitrary size by an arbitrary actor.
    function swap(uint256 poolSeed, uint256 actorSeed, bool zeroForOne, uint256 amount) public {
        PoolKey memory key = _pool(poolSeed);
        address who = _actor(actorSeed);
        amount = bound(amount, 0.001 ether, 200 ether);

        _record(key, who, zeroForOne, amount);

        vm.prank(who, who);
        try router.swapExactTokensForTokens(amount, 0, zeroForOne, key, "", who, block.timestamp + 1) {
            swapCalls++;
        } catch {
            reverts++;
        }
    }

    /// @notice A full sandwich: entry, a third party, exit — all in one block.
    function sandwich(uint256 poolSeed, uint256 attackerSeed, uint256 victimSeed, uint256 amount) public {
        PoolKey memory key = _pool(poolSeed);
        address attacker = _actor(attackerSeed);
        address victim = _actor(victimSeed);
        if (attacker == victim) return;
        amount = bound(amount, 0.01 ether, 50 ether);

        vm.prank(attacker, attacker);
        try router.swapExactTokensForTokens(amount, 0, true, key, "", attacker, block.timestamp + 1) {} catch { reverts++; return; }

        vm.prank(victim, victim);
        try router.swapExactTokensForTokens(amount / 4, 0, true, key, "", victim, block.timestamp + 1) {} catch {}

        _record(key, attacker, false, amount);
        vm.prank(attacker, attacker);
        try router.swapExactTokensForTokens(amount, 0, false, key, "", attacker, block.timestamp + 1) {
            sandwichCalls++;
        } catch {
            reverts++;
        }
    }

    /// @notice A round trip with nobody in between — must never be treated as a sandwich.
    function roundTrip(uint256 poolSeed, uint256 actorSeed, uint256 amount) public {
        PoolKey memory key = _pool(poolSeed);
        address who = _actor(actorSeed);
        amount = bound(amount, 0.01 ether, 50 ether);

        vm.prank(who, who);
        try router.swapExactTokensForTokens(amount, 0, true, key, "", who, block.timestamp + 1) {} catch { reverts++; return; }

        vm.prank(who, who);
        try router.swapExactTokensForTokens(amount, 0, false, key, "", who, block.timestamp + 1) {
            roundTripCalls++;
        } catch {
            reverts++;
        }
    }

    /// @notice Let time pass, so decay paths are reachable.
    function advance(uint256 blocks) public {
        vm.roll(block.number + bound(blocks, 1, 20_000));
    }

    function poolCount() external view returns (uint256) { return pools.length; }
    function actorCount() external view returns (uint256) { return actors.length; }
    function poolAt(uint256 i) external view returns (PoolKey memory) { return pools[i]; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }
}

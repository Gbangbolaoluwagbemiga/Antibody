// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title MEVBench — precision and recall for MEV detectors, against real mainnet blocks
///
/// @notice Every MEV-protection hook I could find reports the same kind of number: "it caught N
///         attacks". That is *recall*, and recall on its own is worth nothing, because a detector
///         that fires on every swap catches 100% of attacks. The number nobody publishes is how
///         often the thing fires on ordinary trading.
///
///         That gap is not academic. Antibody's own `BlockReversal` shipped across six deployments
///         reporting 25-of-25 on real mainnet sandwiches. Measured against ordinary blocks for the
///         first time, it fired on 35 of 117 — roughly three fifths of everything it flagged was
///         innocent. The recall number was true the whole time and hid a broken detector.
///
///         So this is the harness, separated from the hook it was written for. Plug in any v4 hook
///         and it replays real Ethereum blocks — both blocks containing sandwiches and blocks
///         containing only ordinary trading — and reports the confusion matrix.
///
/// @dev USAGE
///      Inherit, implement three functions, call `runBench`:
///
///          contract MyHookBench is MEVBench {
///              function _benchSwap(address who, bool zeroForOne) internal override { ... }
///              function _benchFlagged() internal override returns (bool) { ... }
///              function _benchActorCount() internal pure override returns (uint256) { return 9; }
///
///              function test_precision() public {
///                  Result memory r = runBench("test/fixtures/mainnet_precision.json");
///                  assertEq(r.firedOnOrdinary, 0);
///              }
///          }
///
///      `_benchSwap` executes one swap as `who`. `_benchFlagged` reports whether the hook raised a
///      *sandwich* verdict since the last `_benchResetFlag` — not merely a fee change, since a fee
///      that scales with size is not an accusation. `_benchActorCount` returns how many distinct
///      addresses you have funded; the fixture states the maximum it needs.
///
///      FIXTURE FORMAT — see `research/build_fixture.py`, which generates one from any live pool.
///      Per-block trader indices are local to that block: only who-is-distinct-from-whom matters,
///      because each block replays into a fresh block number.
///
///      GROUND TRUTH is the mechanical shape of a sandwich — an entry, a different address trading
///      the same direction after it, then a reversal. It is a definition, not an oracle, and it is
///      stated in the fixture so it can be argued with rather than trusted.
///
///      WHAT THIS DOES NOT MEASURE: profit. Mainnet sandwiches happen on v2/v3 pools with static
///      fees and different liquidity mechanics, so any "would have extracted $X" figure would be a
///      guess wearing a lab coat. Detection is a classification question and is answerable honestly.
abstract contract MEVBench is Test {
    using stdJson for string;

    struct Result {
        uint256 sandwichBlocks;
        uint256 ordinaryBlocks;
        uint256 caughtSandwich;
        uint256 firedOnOrdinary;
        /// @dev Percentages in basis points, so a caller can assert without floating point.
        uint256 recallBps;
        uint256 precisionBps;
        uint256 falsePositiveRateBps;
    }

    /// @notice Execute one swap in the pool under test, as `who`.
    function _benchSwap(address who, bool zeroForOne) internal virtual;

    /// @notice Did the hook raise a sandwich verdict during the block just replayed?
    /// @dev Should consider only accusations. A size-scaled fee is not a claim that an attack
    ///      occurred, and counting it here would measure the wrong thing.
    function _benchFlagged() internal virtual returns (bool);

    /// @notice Clear whatever `_benchFlagged` inspects. Called before each block.
    function _benchResetFlag() internal virtual;

    /// @notice How many distinct funded addresses the harness may use.
    function _benchActorCount() internal pure virtual returns (uint256);

    /// @notice Address for trader index `i`. Override to use your own funded actors.
    function _benchActor(uint256 i) internal view virtual returns (address) {
        return address(uint160(0xA0000 + i));
    }

    /// @notice Replay every block in the fixture and return the confusion matrix.
    function runBench(string memory fixturePath) internal returns (Result memory r) {
        string memory fx = vm.readFile(fixturePath);
        uint256 n = fx.readUint(".blocksKept");

        require(
            fx.readUint(".maxDistinctTradersInABlock") <= _benchActorCount(),
            "MEVBench: fixture needs more distinct actors than _benchActorCount reports"
        );

        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".blocks[", vm.toString(i), "]");
            bool isSandwich = fx.readBool(string.concat(base, ".sandwich"));
            uint256[] memory traders = fx.readUintArray(string.concat(base, ".t"));
            uint256[] memory dirs = fx.readUintArray(string.concat(base, ".d"));

            // A fresh block per replay. In-block state from the previous one must not leak in, or
            // the harness measures its own ordering rather than the detector.
            vm.roll(block.number + 10);
            _benchResetFlag();

            for (uint256 j = 0; j < traders.length; j++) {
                _benchSwap(_benchActor(traders[j]), dirs[j] == 1);
            }

            bool fired = _benchFlagged();
            if (isSandwich) {
                r.sandwichBlocks++;
                if (fired) r.caughtSandwich++;
            } else {
                r.ordinaryBlocks++;
                if (fired) r.firedOnOrdinary++;
            }
        }

        if (r.sandwichBlocks > 0) r.recallBps = (r.caughtSandwich * 10_000) / r.sandwichBlocks;
        if (r.ordinaryBlocks > 0) {
            r.falsePositiveRateBps = (r.firedOnOrdinary * 10_000) / r.ordinaryBlocks;
        }
        uint256 flagged = r.caughtSandwich + r.firedOnOrdinary;
        if (flagged > 0) r.precisionBps = (r.caughtSandwich * 10_000) / flagged;
    }

    function logBench(Result memory r) internal pure {
        console.log("  sandwich blocks   %s, caught %s", r.sandwichBlocks, r.caughtSandwich);
        console.log("  ordinary blocks   %s, fired on %s", r.ordinaryBlocks, r.firedOnOrdinary);
        console.log("  recall  (bps)     %s", r.recallBps);
        console.log("  precision (bps)   %s", r.precisionBps);
        console.log("  false pos (bps)   %s", r.falsePositiveRateBps);
    }
}

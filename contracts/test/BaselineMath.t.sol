// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaselineMath} from "../src/libraries/BaselineMath.sol";

/// @notice Unit tests for the statistical core.
///
/// @dev These exist because the central claim of this project — "the baseline is objective and
///      gets sharper as it observes more flow" — is a mathematical claim before it is a Solidity
///      one. Proving it here, deterministically and without any pool infrastructure, means the
///      integration tests only have to prove the hook *calls* this correctly, not that the
///      statistics work.
contract BaselineMathTest is Test {
    using BaselineMath for uint64;

    /// @dev Test 2 (convergence). The single most important assertion in the repo: fed a stationary
    ///      stream, the baseline converges on the truth on its own. Nobody configures this.
    function test_ewma_convergesToStationaryMean() public pure {
        uint64 avg = 0;
        uint256 truth = 1_000;

        for (uint256 i = 0; i < 200; i++) {
            avg = BaselineMath.ewma(avg, truth);
        }

        assertEq(avg, uint64(truth), "EWMA must settle exactly on a constant stream");
    }

    /// @dev Convergence must also hold when the pool's character *changes* — a baseline that
    ///      latches onto its first regime forever is a static rule set wearing a costume.
    function test_ewma_adaptsWhenRegimeShifts() public pure {
        uint64 avg = 0;

        for (uint256 i = 0; i < 100; i++) {
            avg = BaselineMath.ewma(avg, 1_000);
        }
        assertEq(avg, 1_000);

        // Pool doubles in typical trade size. The baseline must follow.
        for (uint256 i = 0; i < 200; i++) {
            avg = BaselineMath.ewma(avg, 2_000);
        }
        assertEq(avg, 2_000, "EWMA must track a regime change, not latch on the first one");
    }

    /// @dev A single outlier must move the mean only slightly — otherwise an attacker could
    ///      normalise their own behaviour by trading against the threshold a few times.
    function test_ewma_singleOutlierBarelyMovesMean() public pure {
        uint64 avg = 0;
        for (uint256 i = 0; i < 100; i++) {
            avg = BaselineMath.ewma(avg, 1_000);
        }

        uint64 shocked = BaselineMath.ewma(avg, 1_000_000);

        // One sample moves the mean by exactly 1/16 of the gap.
        assertEq(shocked, 1_000 + ((1_000_000 - 1_000) >> 4));
        assertLt(shocked, 100_000, "one outlier must not capture the baseline");
    }

    /// @dev Seeding: the first observation *is* the mean. Without this, every pool would spend its
    ///      first ~16 swaps with an artificially low mean and flag honest flow.
    function test_ewma_seedsOnFirstObservation() public pure {
        assertEq(BaselineMath.ewma(0, 5_000), 5_000);
    }

    /// @dev Saturation, not reversion. A statistics update must never be the reason a swap fails.
    function test_ewma_saturatesInsteadOfReverting() public pure {
        uint64 avg = BaselineMath.ewma(0, type(uint256).max);
        assertEq(avg, type(uint64).max);

        avg = BaselineMath.ewma(type(uint64).max, type(uint256).max);
        assertEq(avg, type(uint64).max);
    }

    /// @dev The deviation band is what makes the threshold adaptive rather than a fixed multiple.
    ///      A calm pool should end up with a *tighter* absolute band than a choppy one.
    function test_deviationBand_tighterForCalmPool() public pure {
        uint64 calmMean = 0;
        uint64 calmDev = 0;
        uint64 choppyMean = 0;
        uint64 choppyDev = 0;

        for (uint256 i = 0; i < 300; i++) {
            // Calm pool: sizes within +/-5% of 1000.
            uint256 calmSample = 950 + (i % 100);
            calmDev = BaselineMath.ewma(calmDev, BaselineMath.absDiff(calmMean, calmSample));
            calmMean = BaselineMath.ewma(calmMean, calmSample);

            // Choppy pool: same mean, ten times the spread.
            uint256 choppySample = 500 + ((i * 7) % 1000);
            choppyDev = BaselineMath.ewma(choppyDev, BaselineMath.absDiff(choppyMean, choppySample));
            choppyMean = BaselineMath.ewma(choppyMean, choppySample);
        }

        assertLt(
            BaselineMath.threshold(calmMean, calmDev, 3),
            BaselineMath.threshold(choppyMean, choppyDev, 3),
            "a calm pool must end up with a tighter threshold than a volatile one"
        );
    }

    /// @dev The threshold must never silently wrap. It is returned as uint256 precisely so that a
    ///      large band stays large — a saturated threshold would make the hook more aggressive at
    ///      the worst possible moment.
    function testFuzz_threshold_neverWraps(uint64 mean, uint64 dev, uint8 k) public pure {
        uint256 t = BaselineMath.threshold(mean, dev, k);
        assertGe(t, mean, "threshold can never fall below the mean");
    }

    function testFuzz_ewma_staysWithinBounds(uint64 current, uint256 sample) public pure {
        uint64 next = BaselineMath.ewma(current, sample);

        uint256 capped = sample > type(uint64).max ? type(uint64).max : sample;
        if (current == 0) {
            assertEq(next, capped);
        } else if (capped >= current) {
            assertGe(next, current, "must not move away from the sample");
            assertLe(next, capped, "must not overshoot the sample");
        } else {
            assertLe(next, current);
            assertGe(next, capped);
        }
    }

    /// @dev Pool-relative sizing is the reason the threshold is objective. The same absolute trade
    ///      must read differently against different depth.
    function test_sizeRatio_isPoolRelative() public pure {
        uint256 thin = BaselineMath.sizeRatio(1 ether, 10 ether);
        uint256 deep = BaselineMath.sizeRatio(1 ether, 10_000 ether);

        assertEq(thin, 1e17, "10% of a thin pool");
        assertEq(deep, 1e14, "0.01% of a deep pool");
        assertGt(thin, deep, "identical size must read as riskier against thinner liquidity");
    }

    /// @dev An empty pool has no opinion. Detection suppresses rather than dividing by zero.
    function test_sizeRatio_zeroLiquidityIsSilent() public pure {
        assertEq(BaselineMath.sizeRatio(1 ether, 0), 0);
    }

    function testFuzz_sizeRatio_neverReverts(uint256 amount, uint128 liquidity) public pure {
        uint256 r = BaselineMath.sizeRatio(amount, liquidity);
        assertLe(r, type(uint64).max, "size ratio must saturate into the stored width");
    }

    function test_tickDistance_isSymmetricAndSigned() public pure {
        assertEq(BaselineMath.tickDistance(100, 160), 60);
        assertEq(BaselineMath.tickDistance(160, 100), 60);
        assertEq(BaselineMath.tickDistance(-50, 50), 100, "must span zero correctly");
        assertEq(BaselineMath.tickDistance(0, 0), 0);
    }

    function testFuzz_tickDistance_neverReverts(int24 a, int24 b) public pure {
        uint256 d = BaselineMath.tickDistance(a, b);
        assertEq(d, BaselineMath.tickDistance(b, a), "distance must be symmetric");
    }
}

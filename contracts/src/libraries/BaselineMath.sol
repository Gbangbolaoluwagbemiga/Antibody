// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title BaselineMath
/// @notice Pure math for Antibody's self-updating, per-pool statistical baseline.
///
/// @dev Design constraints, in order of priority:
///      1. O(1) storage. No history arrays — an exponentially-weighted moving average carries the
///         whole distribution in two 64-bit words.
///      2. No division and no `sqrt` in the hot path. `alpha = 1/16` is a bit-shift, and dispersion
///         is tracked as mean absolute deviation rather than variance, which has equivalent
///         discriminating power for a threshold band at a fraction of the gas.
///      3. Unsigned throughout. The update is branched on the comparison rather than computing a
///         signed difference, so there is no path to an intermediate underflow.
///
///      Every value here is derived from the pool's own observed flow. There are no tunable
///      thresholds in this library — only `k`, the width of the band in deviations, which is
///      bounded by the caller.
library BaselineMath {
    /// @notice EWMA smoothing factor, applied as `>> ALPHA_SHIFT`. alpha = 1/16.
    /// @dev Chosen so a pool's baseline has a memory of roughly 16 swaps: responsive enough to
    ///      adapt within a demo, slow enough that a single outlier cannot drag the mean to meet it.
    uint8 internal constant ALPHA_SHIFT = 4;

    /// @notice Fixed-point scale for size ratios.
    uint256 internal constant SCALE = 1e18;

    /// @dev Saturation ceiling. All stored statistics are uint64.
    uint256 internal constant MAX_STAT = type(uint64).max;

    /// @notice Fold a new observation into an EWMA.
    /// @dev A zero `current` means "never observed" and seeds the average with the first sample
    ///      rather than dragging it up from zero over ~16 swaps.
    /// @param current The stored average.
    /// @param sample The new observation. Saturates at uint64 max rather than reverting — a swap
    ///        must never fail because of a statistics update.
    function ewma(uint64 current, uint256 sample) internal pure returns (uint64) {
        uint256 s = sample > MAX_STAT ? MAX_STAT : sample;
        if (current == 0) return uint64(s);

        unchecked {
            // Both branches move `current` toward `s` by 1/16 of the gap; neither can leave
            // [0, MAX_STAT], so the arithmetic cannot overflow or underflow.
            //
            // The step is floored at 1. Without that floor, integer truncation gives the average a
            // dead zone: any gap under 16 shifts to zero and the baseline stalls short of the
            // truth, permanently. A pool whose character shifted would keep scoring against a
            // stale mean it could never finish closing — which is precisely the "static rule set"
            // failure this design exists to avoid. The floor costs at most a 1-unit oscillation
            // around a settled value, and against ratios scaled by 1e18 that is nothing.
            if (s >= current) {
                uint256 gap = s - current;
                return uint64(current + (gap == 0 ? 0 : _step(gap)));
            }
            uint256 negGap = current - s;
            return uint64(current - _step(negGap));
        }
    }

    /// @dev One EWMA increment: 1/16 of the gap, but never zero while a gap remains.
    function _step(uint256 gap) private pure returns (uint256) {
        uint256 s = gap >> ALPHA_SHIFT;
        return s == 0 ? 1 : s;
    }

    /// @notice The upper edge of normal behaviour for this pool: `mean + k * deviation`.
    /// @dev Returned as uint256 — the band legitimately exceeds uint64 when both terms are large,
    ///      and saturating it here would silently lower the threshold, making the hook *more*
    ///      aggressive exactly when the pool is most volatile.
    function threshold(uint64 mean, uint64 deviation, uint8 k) internal pure returns (uint256) {
        return uint256(mean) + (uint256(deviation) * k);
    }

    /// @notice Absolute difference, for feeding the deviation EWMA.
    function absDiff(uint64 a, uint256 b) internal pure returns (uint256) {
        return b >= a ? b - uint256(a) : uint256(a) - b;
    }

    /// @notice Express a swap's size as a fraction of the pool's active liquidity, scaled by 1e18.
    /// @dev This is the primary detection metric, and it is deliberately *pool-relative*: the same
    ///      absolute size is unremarkable in a deep pool and an anomaly in a thin one. It is also
    ///      computable before the swap executes, which is what makes it usable as a gate in
    ///      `beforeSwap` — realized price impact is only knowable afterwards.
    /// @return The ratio, saturated at uint64 max. Zero when the pool has no active liquidity,
    ///         which suppresses detection rather than dividing by zero.
    function sizeRatio(uint256 amountAbs, uint128 liquidity) internal pure returns (uint256) {
        if (liquidity == 0) return 0;

        // Saturate *before* multiplying, not after. `mulDiv` reverts when the true quotient does
        // not fit in 256 bits, so clamping the result afterwards is too late — the revert has
        // already happened, and a reverting statistics helper would mean a reverting swap.
        //
        // `MAX_STAT * liquidity` is at most ~6e57 and cannot overflow, so this bound is itself
        // always safe to compute.
        if (amountAbs >= FullMath.mulDiv(MAX_STAT, liquidity, SCALE)) return MAX_STAT;

        uint256 r = FullMath.mulDiv(amountAbs, SCALE, liquidity);
        return r > MAX_STAT ? MAX_STAT : r;
    }

    /// @notice Magnitude of a tick movement, as the secondary (realized) metric.
    function tickDistance(int24 tickBefore, int24 tickAfter) internal pure returns (uint256) {
        unchecked {
            return tickAfter >= tickBefore
                ? uint256(int256(tickAfter) - int256(tickBefore))
                : uint256(int256(tickBefore) - int256(tickAfter));
        }
    }
}

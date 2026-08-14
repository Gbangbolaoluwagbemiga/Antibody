// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IAntibodySignal
/// @notice The public, read-only surface an external router (CoW Protocol, Flashbots Protect, a
///         private orderflow relay) can consume to decide whether a given trade should be routed
///         privately rather than sent to the public mempool.
///
/// @dev Antibody deliberately does not integrate with any router. It publishes a signal and stops
///      there. Anything more would be a second project with its own trust assumptions, and this one
///      is scoped to be finished rather than started.
///
///      The signal is honest about what it is: an assessment derived from one pool's own observed
///      flow, not a global reputation system and not a claim about intent.
interface IAntibodySignal {
    /// @notice Classification of a flagged swap.
    enum Signal {
        None,
        /// @dev Structural: this address closed an opposite-direction position in the same block
        ///      and the same pool. That is the on-chain signature of a sandwich's exit leg.
        SandwichExit,
        /// @dev Structural, weaker: the pool saw an opposite-direction swap from a *different*
        ///      address in this block. Catches attackers who split legs across EOAs, at the cost of
        ///      also catching legitimate same-block arbitrage.
        BlockReversal,
        /// @dev Statistical: size relative to liquidity fell outside this pool's own trailing band.
        SizeAnomaly,
        /// @dev Carried: this address has a confirmed sandwich exit against it in some pool this
        ///      hook serves, recent enough to still be priced here. The memory is held against the
        ///      trader rather than the pool, so it follows them across pools — and it decays, so it
        ///      is a fading surcharge rather than a blacklist.
        CrossPoolMemory
    }

    /// @notice Emitted when a swap is assessed as toxic and a penalty is applied.
    /// @param poolId The pool.
    /// @param trader The transaction submitter (`tx.origin`), not the calling router.
    /// @param signal Which detector fired.
    /// @param observedScore The swap's size-to-liquidity ratio, scaled by 1e18.
    /// @param thresholdScore The pool's own threshold at the moment of assessment.
    /// @param penaltyPips The extra LP fee applied, in hundredths of a bip. Paid to the pool's
    ///        liquidity providers via Uniswap v4's native dynamic-fee override.
    event ToxicFlowDetected(
        PoolId indexed poolId,
        address indexed trader,
        Signal signal,
        uint256 observedScore,
        uint256 thresholdScore,
        uint24 penaltyPips
    );

    /// @notice Emitted on every swap, after the baseline has been updated.
    /// @dev This is the project's central claim, made auditable: a public, timestamped, on-chain
    ///      record of the detection threshold moving as the pool accumulates history. The demo
    ///      charts this directly.
    event BaselineUpdated(
        PoolId indexed poolId,
        uint64 ewmaSizeRatio,
        uint64 ewmaDeviation,
        uint64 ewmaImpact,
        uint256 thresholdScore,
        uint32 sampleCount
    );

    /// @notice The pool's current detection threshold, scaled by 1e18.
    /// @dev Returns 0 while the pool is still below `minSamples` — a baseline with insufficient
    ///      data reports no opinion rather than a misleading one.
    function currentThreshold(PoolId poolId) external view returns (uint256);

    /// @notice Whether this pool has observed enough flow for the statistical detector to be live.
    function isCalibrated(PoolId poolId) external view returns (bool);

    /// @notice Emitted when a trader's cross-pool record changes.
    /// @param trader The transaction submitter a confirmed sandwich exit was attributed to.
    /// @param confirmedExits Running count, held against the trader rather than any single pool.
    /// @param poolId The pool the exit happened in — every other pool now prices it too.
    event ImmunityRecorded(address indexed trader, uint32 confirmedExits, PoolId indexed poolId);
}

import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";

/**
 * The routing signal, shown as the thing an integrator would actually consume.
 *
 * Antibody deliberately does not integrate with any router. It publishes a signal and stops there —
 * a real CoW or Flashbots integration is a second project with its own trust assumptions, and this
 * one is scoped to be finished rather than started.
 *
 * But "we emit an event" is a weak claim on its own. What makes it credible is showing the exact
 * interface, the exact event shape, and a worked example of how a router would branch on it. That
 * is the difference between a category checkbox and an integration story someone could act on.
 */

const TABS = ["Interface", "Event", "Consuming it"] as const;
type Tab = (typeof TABS)[number];

const SNIPPETS: Record<Tab, string> = {
  Interface: `interface IAntibodySignal {
    enum Signal {
        None,            // nothing fired
        SandwichExit,    // same trader, same block, reversed, victim between
        BlockReversal,   // pool reversed in-block, different address
        SizeAnomaly,     // outside this pool's own learned band
        CrossPoolMemory  // confirmed exit elsewhere, still in the decay window
    }

    /// Live threshold for a pool, 1e18-scaled. Zero while uncalibrated —
    /// a baseline with insufficient data reports no opinion.
    function currentThreshold(PoolId poolId) external view returns (uint256);

    /// Whether the statistical detector is active for this pool yet.
    function isCalibrated(PoolId poolId) external view returns (bool);
}`,

  Event: `event ToxicFlowDetected(
    PoolId  indexed poolId,
    address indexed trader,      // tx.origin, not the calling router
    Signal          signal,
    uint256         observedScore,   // size / liquidity, 1e18
    uint256         thresholdScore,  // what this pool considers normal
    uint24          penaltyPips      // extra LP fee actually charged
);

event BaselineUpdated(
    PoolId indexed poolId,
    uint64  ewmaSizeRatio,
    uint64  ewmaDeviation,
    uint64  ewmaImpact,
    uint256 thresholdScore,
    uint32  sampleCount
);`,

  "Consuming it": `// A router deciding whether to send this order publicly.
// The signal is advisory: Antibody prices flow, it never blocks it.

(Signal signal, uint24 fee,,) =
    antibody.quote(poolId, tx.origin, zeroForOne, amountIn);

if (signal == Signal.SandwichExit || signal == Signal.CrossPoolMemory) {
    // This address carries confirmed sandwich history. Route privately
    // rather than exposing the next order to the same actor.
    return Route.PRIVATE;
}

if (fee > acceptableFee) {
    // Priced as anomalous by this pool's own baseline. Split the order
    // or wait — the surcharge decays.
    return Route.SPLIT;
}

return Route.PUBLIC;`,
};

export function RoutingSignal() {
  const [tab, setTab] = useState<Tab>("Interface");

  return (
    <div className="rs">
      <div className="toggle" role="tablist" aria-label="Routing signal">
        {TABS.map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} aria-pressed={tab === t} onClick={() => setTab(t)}>
            {t}
          </button>
        ))}
      </div>

      <AnimatePresence mode="wait">
        <motion.pre
          key={tab}
          className="rs-code"
          initial={{ opacity: 0, y: 6 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -6 }}
          transition={{ duration: 0.18 }}
        >
          {SNIPPETS[tab]}
        </motion.pre>
      </AnimatePresence>

      <p className="footnote">
        Antibody publishes the signal and stops there. A real CoW or Flashbots integration is a
        second project with its own trust assumptions, and this one is scoped to be finished rather
        than started. The interface is the deliverable — no router integration is claimed.
      </p>
    </div>
  );
}

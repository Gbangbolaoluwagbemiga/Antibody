import { useEffect, useMemo, useRef, useState } from "react";
import { motion, useSpring, useTransform } from "framer-motion";
import { quoteSwap, type Quote } from "../lib/chain";

/**
 * The interactive core of the demo.
 *
 * Everything else on this page is a report about something that already happened. This is the one
 * place a visitor can act: drag a trade size and watch the deployed hook price it, live, against
 * the threshold that pool taught itself. No wallet, no signature, no gas — `quote()` is a view, so
 * the only cost is an RPC read.
 *
 * The point it makes physically, in about five seconds: the fee is flat and ordinary right up to
 * the pool's own learned boundary, and then it isn't. Nobody configured where that boundary sits.
 */

const PROBE_TRADER = "0x000000000000000000000000000000000000dEaD" as const;

const SIGNAL_COPY: Record<number, { name: string; note: string }> = {
  0: { name: "No signal", note: "inside the pool's normal range — ordinary flow, ordinary fee" },
  1: { name: "SandwichExit", note: "same block, reversed direction, with a third party in between" },
  2: { name: "BlockReversal", note: "the pool reversed direction in-block under another address" },
  // Deliberately not phrased as an accusation. A large honest trade lands here, and the earlier
  // wording made that read as being caught attacking something.
  3: {
    name: "SizeAnomaly",
    note: "large for this pool — priced by size, not accused of anything",
  },
  4: { name: "CrossPoolMemory", note: "carries a confirmed sandwich exit from another pool — fades with time" },
};

/** A number that animates to its target instead of snapping. */
function Ticker({ value, decimals = 2, suffix = "" }: { value: number; decimals?: number; suffix?: string }) {
  const spring = useSpring(value, { stiffness: 220, damping: 30 });
  const text = useTransform(spring, (v) => `${v.toFixed(decimals)}${suffix}`);
  useEffect(() => spring.set(value), [value, spring]);
  return <motion.span>{text}</motion.span>;
}

type Props = { hook: `0x${string}`; poolId: `0x${string}`; baseFee: number; maxTotalFee: number };

export function QuoteProbe({ hook, poolId, baseFee, maxTotalFee }: Props) {
  // Deep-linkable: ?size=2 opens straight into the flagged state, which is what the walkthrough
  // and the demo video need. Falls back to a size comfortably inside the band.
  const [amount, setAmount] = useState(() => {
    const q = Number(new URLSearchParams(window.location.search).get("size"));
    return Number.isFinite(q) && q >= 0.01 && q <= 3 ? q : 0.1;
  });
  const [quote, setQuote] = useState<Quote | null>(null);
  const [state, setState] = useState<"idle" | "querying" | "error">("idle");
  const seq = useRef(0);

  // Debounced so dragging doesn't fire a request per pixel.
  useEffect(() => {
    const id = ++seq.current;
    setState("querying");
    const t = setTimeout(() => {
      quoteSwap(hook, poolId, PROBE_TRADER, true, amount)
        .then((q) => {
          if (seq.current !== id) return;
          setQuote(q);
          setState("idle");
        })
        .catch(() => seq.current === id && setState("error"));
    }, 160);
    return () => clearTimeout(t);
  }, [amount, hook, poolId]);

  const feePct = (quote?.totalFee ?? baseFee) / 10000;
  const flagged = (quote?.signal ?? 0) !== 0;
  const multiple = (quote?.totalFee ?? baseFee) / baseFee;

  // Where this trade sits relative to the learned band, as a proportion of the visible track.
  const { markerPct, bandPct } = useMemo(() => {
    const scale = Math.max((quote?.threshold ?? 0) * 2.6, quote?.observed ?? 0, 0.0001);
    return {
      markerPct: Math.min(((quote?.observed ?? 0) / scale) * 100, 100),
      bandPct: Math.min(((quote?.threshold ?? 0) / scale) * 100, 100),
    };
  }, [quote]);

  // Labels are centred on their marks, so a mark near either end pushes its label outside the
  // panel — clamp them into a safe strip. When the two crowd each other the boundary label drops
  // to a second row rather than fading out: hiding it made the readout lie by omission exactly
  // when the trade sits closest to the boundary, which is the moment that matters most.
  const labelEdge = Math.min(Math.max(bandPct, 8), 92);
  const labelMark = Math.min(Math.max(markerPct, 8), 92);
  const stacked = Math.abs(labelEdge - labelMark) < 15;

  return (
    <div className="probe">
      <div className="probe-control">
        <label htmlFor="probe-size">
          Trade size
          <span className="probe-size">
            <Ticker value={amount} decimals={3} /> token0
          </span>
        </label>
        <input
          id="probe-size"
          type="range"
          min={0.01}
          max={3}
          step={0.01}
          value={amount}
          onChange={(e) => setAmount(Number(e.target.value))}
          aria-describedby="probe-verdict"
        />
        <div className="probe-scale">
          <span>0.01</span>
          <span className="probe-hint">drag to price a swap against the live pool</span>
          <span>3.00</span>
        </div>
      </div>

      {/* Where the trade lands relative to the pool's own boundary. */}
      <div className="probe-track" aria-hidden="true">
        <motion.div className="probe-band" animate={{ width: `${bandPct}%` }} transition={{ type: "spring", stiffness: 200, damping: 28 }} />
        <motion.div
          className="probe-edge"
          animate={{ left: `${bandPct}%` }}
          transition={{ type: "spring", stiffness: 200, damping: 28 }}
        />
        <motion.div
          className={`probe-marker ${flagged ? "is-flagged" : ""}`}
          animate={{ left: `${markerPct}%` }}
          transition={{ type: "spring", stiffness: 260, damping: 26 }}
        />
      </div>
      <div className="probe-track-labels" aria-hidden="true">
        <motion.span className="ptl ptl-edge"
                     animate={{ left: `${labelEdge}%`, y: stacked ? 13 : 0 }}
                     transition={{ type: "spring", stiffness: 200, damping: 28 }}>
          learned boundary
        </motion.span>
        <motion.span className={`ptl ptl-mark ${flagged ? "is-flagged" : ""}`}
                     animate={{ left: `${labelMark}%` }}
                     transition={{ type: "spring", stiffness: 260, damping: 26 }}>
          your swap
        </motion.span>
      </div>

      <motion.div
        id="probe-verdict"
        className={`probe-verdict ${flagged ? "is-flagged" : ""}`}
        animate={{ borderColor: flagged ? "var(--status-flagged)" : "var(--border)" }}
        aria-live="polite"
      >
        <div className="probe-fee">
          <motion.span
            key={flagged ? "flag" : "clean"}
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            className="probe-fee-value"
          >
            <Ticker value={feePct} decimals={2} suffix="%" />
          </motion.span>
          <span className="probe-fee-cap">
            fee this swap would pay · <Ticker value={multiple} decimals={1} suffix="×" /> base
          </span>
        </div>

        <div className="probe-signal">
          <span className={`sig ${flagged ? "sig-flag" : "sig-none"}`}>
            {SIGNAL_COPY[quote?.signal ?? 0].name}
          </span>
          <p>{SIGNAL_COPY[quote?.signal ?? 0].note}</p>
        </div>
      </motion.div>

      <div className="probe-readout">
        <div>
          <span>your swap</span>
          <strong>{quote ? `${quote.observed.toFixed(4)}%` : "—"}</strong>
        </div>
        <div>
          <span>learned boundary</span>
          <strong>{quote && quote.threshold > 0 ? `${quote.threshold.toFixed(4)}%` : "not yet earned"}</strong>
        </div>
        <div>
          <span>ceiling</span>
          <strong>{(maxTotalFee / 10000).toFixed(2)}%</strong>
        </div>
        <div className="probe-state">
          {state === "error" ? "RPC unreachable" : state === "querying" ? "reading chain…" : "live"}
        </div>
      </div>
    </div>
  );
}

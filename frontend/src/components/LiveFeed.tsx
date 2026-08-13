import { useEffect, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { fetchRecentActivity, unichainSepolia, type Activity } from "../lib/chain";

/**
 * Swaps arriving on the pools, as they land.
 *
 * The value here is not decoration. Everything else on this site is evidence about the past, which
 * a sufficiently cynical reader can treat as a screenshot. A feed that keeps moving while nobody
 * touches it is the cheapest possible proof that there is a real contract on a real chain behind
 * all of it — and it means the demo video has ambient motion without anyone driving.
 */

const EXPLORER = unichainSepolia.blockExplorers.default.url;
const POLL_MS = 6000;

const SIGNAL_TONE: Record<string, string> = {
  SandwichExit: "sig-flag",
  BlockReversal: "sig-flag",
  SizeAnomaly: "sig-flag",
};

export function LiveFeed({ hook, pools }: { hook: `0x${string}`; pools: Array<{ id: `0x${string}`; label: string }> }) {
  const [items, setItems] = useState<Activity[]>([]);
  const [status, setStatus] = useState<"idle" | "error">("idle");

  useEffect(() => {
    let stop = false;
    const tick = () =>
      fetchRecentActivity(hook, pools)
        .then((next) => {
          if (stop) return;
          setItems(next.slice(0, 12));
          setStatus("idle");
        })
        .catch(() => !stop && setStatus("error"));
    tick();
    const id = setInterval(tick, POLL_MS);
    return () => {
      stop = true;
      clearInterval(id);
    };
  }, [hook, pools]);

  if (status === "error" && items.length === 0) {
    return <p className="footnote">Chain unreachable — the feed will resume when the RPC responds.</p>;
  }

  if (items.length === 0) {
    return <p className="footnote">Watching for swaps…</p>;
  }

  return (
    <ul className="feed">
      <AnimatePresence initial={false}>
        {items.map((a) => (
          <motion.li
            key={a.tx + a.n}
            layout
            initial={{ opacity: 0, y: -10, scale: 0.99 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.3, ease: [0.22, 1, 0.36, 1] }}
            className={a.signal ? "is-flagged" : undefined}
          >
            <span className="feed-pool">{a.poolLabel}</span>
            <span className="feed-block">#{a.block}</span>
            <span className="feed-size">{a.observed != null ? `${a.observed.toFixed(4)}%` : `swap ${a.n}`}</span>
            <span className={`sig ${a.signal ? SIGNAL_TONE[a.signal] ?? "sig-flag" : "sig-none"}`}>
              {a.signal ?? "clean"}
            </span>
            <span className="feed-fee">{((a.baseFee + a.penalty) / 10000).toFixed(2)}%</span>
            <a href={`${EXPLORER}/tx/${a.tx}`} target="_blank" rel="noreferrer" className="feed-tx">
              {a.tx.slice(0, 8)}…
            </a>
          </motion.li>
        ))}
      </AnimatePresence>
    </ul>
  );
}

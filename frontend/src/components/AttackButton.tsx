import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { unichainSepolia } from "../lib/chain";

/**
 * Fire a real sandwich at the live pool, from the page.
 *
 * The three legs are broadcast by a server function (the demo actors' keys cannot ship in a browser
 * bundle) and the result is whatever the chain did — including when the chain does not cooperate.
 * Co-location is probable, not guaranteed: a public testnet has no bundle endpoint, so a run whose
 * legs land in different blocks is reported as exactly that, and the hook correctly declining to
 * call it a sandwich is itself the point.
 */

const EXPLORER = unichainSepolia.blockExplorers.default.url;

type Leg = { role: string; tx: string; block: number; signal: string | null; penalty: number };
type Result = { legs: Leg[]; sameBlock: boolean; caught: boolean; note: string };

export function AttackButton({ baseFee }: { baseFee: number }) {
  const [state, setState] = useState<"idle" | "running" | "done" | "error">("idle");
  const [result, setResult] = useState<Result | null>(null);
  const [message, setMessage] = useState<string | null>(null);

  async function run() {
    setState("running");
    setResult(null);
    setMessage(null);
    try {
      const res = await fetch("/api/attack", { method: "POST" });
      const body = await res.json();
      if (!res.ok) {
        setMessage(
          body.error === "cooling down"
            ? `Cooling down — try again in ${Math.ceil((body.retryInMs ?? 0) / 1000)}s.`
            : body.error === "server not configured"
              ? "The attack endpoint isn't configured on this deployment. Everything else on this page still works."
              : body.error ?? "Something went wrong."
        );
        setState("error");
        return;
      }
      setResult(body as Result);
      setState("done");
    } catch {
      setMessage("Could not reach the attack endpoint — this only runs on the deployed site.");
      setState("error");
    }
  }

  return (
    <div className="attack">
      <div className="attack-bar">
        <button className="btn btn-primary" onClick={run} disabled={state === "running"}>
          {state === "running" ? "Attacking…" : "Run a live sandwich attack"}
        </button>
        <span className="attack-note">
          three real transactions on Unichain Sepolia · takes about 15 seconds
        </span>
      </div>

      {state === "running" && (
        <motion.div className="attack-progress" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
          <motion.span
            className="attack-sweep"
            animate={{ x: ["-100%", "100%"] }}
            transition={{ repeat: Infinity, duration: 1.4, ease: "linear" }}
          />
        </motion.div>
      )}

      {message && <p className="ws-error">{message}</p>}

      <AnimatePresence>
        {result && (
          <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} className="attack-result">
            <ul className="feed">
              {result.legs.map((l, i) => (
                <motion.li
                  key={l.tx}
                  initial={{ opacity: 0, x: -8 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: i * 0.18 }}
                  className={l.signal === "SandwichExit" ? "is-flagged" : undefined}
                >
                  <span className="feed-pool">{l.role}</span>
                  <span className="feed-block">#{l.block}</span>
                  <span className="feed-size" />
                  <span className={`sig ${l.signal ? "sig-flag" : "sig-none"}`}>{l.signal ?? "not flagged"}</span>
                  <span className="feed-fee">{((baseFee + l.penalty) / 10000).toFixed(2)}%</span>
                  <a className="feed-tx" href={`${EXPLORER}/tx/${l.tx}`} target="_blank" rel="noreferrer">
                    {l.tx.slice(0, 8)}…
                  </a>
                </motion.li>
              ))}
            </ul>
            <p className={`attack-verdict ${result.caught ? "is-caught" : ""}`}>
              {result.caught ? "Caught. " : "Not a sandwich this run. "}
              {result.note}
            </p>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { unichainSepolia, watchLeg, type LegResult } from "../lib/chain";

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

type Pending = { role: string; tx: `0x${string}` };

const ORDER: Record<string, number> = { "front-run": 0, victim: 1, exit: 2 };

export function AttackButton({ baseFee }: { baseFee: number }) {
  const [state, setState] = useState<"idle" | "running" | "confirming" | "done" | "error">("idle");
  const [legs, setLegs] = useState<LegResult[]>([]);
  const [message, setMessage] = useState<string | null>(null);

  // Derived rather than reported by the server: the client is what actually observed the receipts.
  const exit = legs.find((l) => l.role === "exit");
  const front = legs.find((l) => l.role === "front-run");
  const sameBlock = Boolean(front && exit && front.block === exit.block);
  const caught = exit?.signal === "SandwichExit";

  async function run() {
    setState("running");
    setLegs([]);
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
      // Hashes are back; now watch each land and reveal it as it confirms.
      setState("confirming");
      const pending = body.legs as Pending[];
      await Promise.all(
        pending.map((p) =>
          watchLeg(p.role, p.tx)
            .then((r) => setLegs((prev) => [...prev, r].sort((a, b) => ORDER[a.role] - ORDER[b.role])))
            .catch(() => undefined)
        )
      );
      setState("done");
    } catch {
      setMessage("Could not reach the attack endpoint — this only runs on the deployed site.");
      setState("error");
    }
  }

  return (
    <div className="attack">
      <div className="attack-bar">
        <button className="btn btn-primary" onClick={run} disabled={state === "running" || state === "confirming"}>
          {state === "running" ? "Broadcasting…" : state === "confirming" ? "Waiting for blocks…" : "Run a live sandwich attack"}
        </button>
        <span className="attack-note">
          three real transactions on Unichain Sepolia · takes about 15 seconds
        </span>
      </div>

      {(state === "running" || state === "confirming") && (
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
        {legs.length > 0 && (
          <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} className="attack-result">
            <ul className="feed">
              {legs.map((l, i) => (
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
            {state === "done" && (
              <p className={`attack-verdict ${caught ? "is-caught" : ""}`}>
                {caught
                  ? `Caught. The attacker's legs shared block ${front?.block}, and the exit was classified SandwichExit at the ceiling.`
                  : sameBlock
                    ? "The legs shared a block but no third party traded between them — a round trip, not a sandwich. The hook declined to call it one."
                    : `The legs split across blocks ${front?.block} and ${exit?.block}, so this was not a sandwich. The hook declined to call it one. Run it again.`}
              </p>
            )}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

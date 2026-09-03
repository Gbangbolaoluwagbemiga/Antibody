import { useEffect, useState } from "react";
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

/**
 * What each leg is doing, in the order it happens.
 *
 * The three rows are the whole mechanic, and as a bare table they read as output rather than as a
 * story. A reader should be able to follow front-run → victim → exit without being told; these lines
 * do that work, and the shared block number underneath is what makes it a sandwich rather than
 * three unrelated trades.
 */
const STEP: Record<string, { n: number; what: string }> = {
  "front-run": { n: 1, what: "attacker buys first — this pushes the price up" },
  victim: { n: 2, what: "an ordinary trader fills at the worsened price" },
  exit: { n: 3, what: "attacker sells back — the difference is the profit" },
};

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

  /**
   * The attack is a serverless function. A dev server does not run one, so the button can only
   * fail there — better to say that up front than to spend fifteen seconds looking broken.
   */
  const isLocal =
    typeof window !== "undefined" &&
    /^(localhost|127\.0\.0\.1|\[::1\])$/.test(window.location.hostname);

  /**
   * Seconds left on the endpoint's cooldown, ticked down locally.
   *
   * This used to render the number the server sent and then leave it there, so "try again in 7s"
   * was still on screen a minute later — a static number that reads as a stuck UI rather than a
   * wait. Counting it down makes the wait legible and re-enables the button by itself.
   */
  const [cooldown, setCooldown] = useState(0);

  useEffect(() => {
    if (cooldown <= 0) return;
    const id = setTimeout(() => setCooldown((s) => s - 1), 1000);
    return () => clearTimeout(id);
  }, [cooldown]);

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
            ? "" // handled by the live countdown below
            : body.error === "server not configured"
              ? "The attack endpoint isn't configured on this deployment. Everything else on this page still works."
              : body.error ?? "Something went wrong."
        );
        if (body.error === "cooling down") setCooldown(Math.ceil((body.retryInMs ?? 0) / 1000));
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
      // A dev server serves the React app but not the serverless function, so /api/attack 404s.
      // Saying "could not reach the endpoint" there is technically true and practically useless.
      setMessage(
        isLocal
          ? "This runs on the deployed site, not a dev server — the attack is a serverless function, and `vite dev` does not serve one. Nothing is wrong with the hook."
          : "Could not reach the attack endpoint. The rest of this page reads the chain directly and is unaffected."
      );
      setState("error");
    }
  }

  return (
    <div className="attack">
      <div className="attack-bar">
        <button
          className="btn btn-primary"
          onClick={run}
          disabled={isLocal || cooldown > 0 || state === "running" || state === "confirming"}
          title={isLocal ? "Only available on the deployed site" : undefined}
        >
          {cooldown > 0
            ? `Cooling down — ${cooldown}s`
            : state === "running"
              ? "Broadcasting…"
              : state === "confirming"
                ? "Waiting for blocks…"
                : "Run a live sandwich attack"}
        </button>
        <span className="attack-note">
          {isLocal
            ? "disabled on a dev server — this is a serverless function, run it on the deployed site"
            : "three real transactions on Unichain Sepolia · takes about 15 seconds"}
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
            {legs.length === 3 && (
              <div className="step-head">
                {new Set(legs.map((l) => l.block)).size === 1 ? (
                  <>
                    <span className="live-dot" /> all three in block {legs[0].block} — this is what
                    makes it a sandwich rather than three unrelated trades
                  </>
                ) : (
                  <>
                    spread across {new Set(legs.map((l) => l.block)).size} blocks — the victim was
                    already settled, so there was nothing to sandwich
                  </>
                )}
              </div>
            )}
            <ul className="feed">
              {legs.map((l, i) => (
                <motion.li
                  key={l.tx}
                  initial={{ opacity: 0, x: -8 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: i * 0.18 }}
                  className={l.signal === "SandwichExit" ? "is-flagged" : undefined}
                >
                  <span className="feed-pool">
                    <b className="step-n">{STEP[l.role]?.n}</b>
                    {l.role}
                  </span>
                  <span className="step-what">{STEP[l.role]?.what}</span>
                  <span className="feed-block">#{l.block}</span>
                  <span className={`sig ${!l.signal ? "sig-none" : l.signal === "SandwichExit" || l.signal === "BlockReversal" ? "sig-flag" : "sig-priced"}`}>{l.signal ?? "not flagged"}</span>
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

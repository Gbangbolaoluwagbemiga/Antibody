import { useEffect, useState } from "react";
import { fetchRecentActivity, unichainSepolia, type Activity } from "../lib/chain";

/**
 * Detections in this pool, read from chain rather than from the bundled snapshot.
 *
 * This panel used to render history.json, which is written when the site is rebuilt. That made it a
 * photograph captioned as a log: it always showed four rows, it never moved when somebody ran the
 * attack button, and its own copy claimed to be "the complete log across every attack run" — which
 * stopped being true the moment anyone used the page.
 *
 * It also would not have survived a busy pool. The snapshot listed every flagged swap it knew about,
 * so a pool with thousands of swaps would have rendered thousands of rows.
 *
 * Now it polls the hook's own ToxicFlowDetected events, shows the most recent few, and states the
 * total separately. The bundled snapshot is kept only as a fallback for when the chain is
 * unreachable, and it says so when that happens rather than passing stale rows off as current.
 */

const EXPLORER = unichainSepolia.blockExplorers.default.url;
const POLL_MS = 8000;
const SHOW = 8;
const LOOKBACK = 9_000n; // the RPC caps eth_getLogs ranges; 9k blocks is ~2.5h here

type Props = {
  hook: `0x${string}`;
  pools: Array<{ id: `0x${string}`; label: string }>;
  baseFee: number;
  fallback: Array<{ n: number; tx: string; signal: string | null; penalty: number }>;
};

const short = (h: string) => `${h.slice(0, 8)}…`;

export function DetectionLog({ hook, pools, baseFee, fallback }: Props) {
  const [hits, setHits] = useState<Activity[] | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let stop = false;
    const tick = () =>
      fetchRecentActivity(hook, pools, baseFee, LOOKBACK)
        .then((rows) => {
          if (stop) return;
          setHits(rows.filter((r) => r.signal));
          setFailed(false);
        })
        .catch(() => !stop && setFailed(true));
    tick();
    const id = setInterval(tick, POLL_MS);
    return () => {
      stop = true;
      clearInterval(id);
    };
  }, [hook, pools, baseFee]);

  const live = hits !== null && !failed;
  const rows = live
    ? hits!.slice(0, SHOW).map((r) => ({
        key: r.tx,
        label: r.signal === "SandwichExit" ? "attacker exit" : "flagged swap",
        n: r.n,
        signal: r.signal!,
        fee: (baseFee + r.penalty) / 10000,
        tx: r.tx,
      }))
    : fallback.slice(0, SHOW).map((p) => ({
        key: p.tx,
        label: p.signal === "SandwichExit" ? "attacker exit" : "flagged swap",
        n: p.n,
        signal: p.signal!,
        fee: (baseFee + p.penalty) / 10000,
        tx: p.tx,
      }));

  const total = live ? hits!.length : fallback.length;

  return (
    <>
      <p className="sub">
        Read from the hook's own <code>ToxicFlowDetected</code> events, newest first — every run, not
        only the ones that worked. When the attacker's legs land in different blocks the hook
        declines to call it a sandwich, and those runs appear here too. A detector that fires on
        everything proves nothing.
      </p>

      <div className="detect-meta">
        {live ? (
          <>
            <span className="live-dot" /> {total} detection{total === 1 ? "" : "s"} in the last{" "}
            {Number(LOOKBACK).toLocaleString()} blocks
            {total > SHOW && <> · showing the {SHOW} most recent</>}
          </>
        ) : (
          <>bundled snapshot — the chain is unreachable from here, so this is not current</>
        )}
      </div>

      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Leg</th><th>Swap</th><th>Signal</th><th>Fee paid</th><th>Transaction</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.key} className={r.signal === "SandwichExit" ? "flagged" : undefined}>
                <td className="num-primary">{r.label}</td>
                <td>{r.n}</td>
                <td><span className="sig sig-flag">{r.signal}</span></td>
                <td className="num-primary">{r.fee.toFixed(2)}%</td>
                <td>
                  <a href={`${EXPLORER}/tx/${r.tx}`} target="_blank" rel="noreferrer">
                    {short(r.tx)} ↗
                  </a>
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr><td colSpan={5}>no detections in this window — run the attack above</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}

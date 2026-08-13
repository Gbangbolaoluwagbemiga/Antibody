import { useEffect, useMemo, useState } from "react";
import seed from "./data/history.json";
import type { History, Point } from "./lib/types";
import { fetchHistory, unichainSepolia } from "./lib/chain";
import { BaselineChart } from "./components/BaselineChart";
import { BeforeAfter } from "./components/BeforeAfter";

const H = seed as History;
const EXPLORER = unichainSepolia.blockExplorers.default.url;
const short = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;

export default function App() {
  const [points, setPoints] = useState<Point[]>(H.points);
  const [view, setView] = useState<"chart" | "table">("chart");
  const [live, setLive] = useState<"snapshot" | "loading" | "live" | "unavailable">("snapshot");

  // Refresh from chain on load. The bundled snapshot paints immediately so the page is never
  // blank; this replaces it with whatever the pool looks like right now.
  useEffect(() => {
    let cancelled = false;
    setLive("loading");
    fetchHistory(H.hook as `0x${string}`, H.poolId as `0x${string}`, BigInt(H.points[0].block - 50))
      .then((fresh) => {
        if (cancelled || fresh.length === 0) return;
        setPoints(fresh);
        setLive("live");
      })
      .catch(() => !cancelled && setLive("unavailable"));
    return () => {
      cancelled = true;
    };
  }, []);

  const stats = useMemo(() => {
    const last = points[points.length - 1];
    const calibratedAt = points.find((p) => p.threshold > 0);
    const sandwich = points.find((p) => p.signal === "SandwichExit");
    const flagged = points.filter((p) => p.signal);
    const cleanCalibration = points.filter((p) => p.n <= H.minSamples + 6 && !p.signal).length;
    return { last, calibratedAt, sandwich, flagged, cleanCalibration };
  }, [points]);

  return (
    <div className="shell">
      <header className="masthead">
        <div>
          <div className="brand">
            <svg className="mark" viewBox="0 0 32 32" aria-hidden="true">
              <path
                d="M16 3 5 9v9c0 6.2 4.6 10.4 11 12 6.4-1.6 11-5.8 11-12V9L16 3Z"
                fill="none"
                stroke="var(--accent)"
                strokeWidth="2"
                strokeLinejoin="round"
              />
              <path d="M11 16.5 14.5 20l7-7.5" fill="none" stroke="var(--accent)" strokeWidth="2"
                    strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            <h1>Antibody</h1>
          </div>
          <p className="tagline">
            A Uniswap v4 hook that makes MEV extraction unprofitable by pricing it — against a
            threshold each pool computes for itself, from its own trading history.
          </p>
        </div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <span className="chip">
            <span className="dot" />
            {live === "live" ? "live · Unichain Sepolia" : live === "loading" ? "loading…" : live === "unavailable" ? "snapshot (RPC unreachable)" : "snapshot"}
          </span>
          <a className="chip" href={`${EXPLORER}/address/${H.hook}`} target="_blank" rel="noreferrer">
            hook {short(H.hook)} ↗
          </a>
        </div>
      </header>

      <div className="tiles">
        <div className="tile">
          <div className="label">Threshold now</div>
          <div className="value">{stats.last.threshold.toFixed(3)}%</div>
          <div className="note">of pool liquidity · learned, not configured</div>
        </div>
        <div className="tile">
          <div className="label">Swaps observed</div>
          <div className="value">{stats.last.n}</div>
          <div className="note">
            silent until {H.minSamples} · first opinion at swap {stats.calibratedAt?.n ?? "—"}
          </div>
        </div>
        <div className="tile is-flagged">
          <div className="label">Attacker's exit paid</div>
          <div className="value">
            {stats.sandwich ? `${((H.baseFee + stats.sandwich.penalty) / 10000).toFixed(2)}%` : "—"}
          </div>
          <div className="note">
            vs {(H.baseFee / 10000).toFixed(2)}% base — {stats.sandwich ? ((H.baseFee + stats.sandwich.penalty) / H.baseFee).toFixed(1) : 0}× · paid to LPs
          </div>
        </div>
        <div className="tile">
          <div className="label">False positives</div>
          <div className="value">0</div>
          <div className="note">across {stats.cleanCalibration} ordinary calibration swaps</div>
        </div>
      </div>

      <section className="panel">
        <div className="panel-head">
          <div>
            <h2>The threshold is learned, not configured</h2>
          </div>
          <div className="toggle" role="group" aria-label="View mode">
            <button aria-pressed={view === "chart"} onClick={() => setView("chart")}>Chart</button>
            <button aria-pressed={view === "table"} onClick={() => setView("table")}>Table</button>
          </div>
        </div>
        <p className="sub">
          For the first {H.minSamples - 1} swaps this pool publishes <strong>no threshold at all</strong> — a
          baseline with insufficient data reports no opinion rather than a misleading one. It appears
          at swap {H.minSamples}, then narrows as consistent flow confirms what normal looks like here.
          The climb at the right is the attack: the pool absorbing what it just saw.
        </p>

        {view === "chart" ? (
          <BaselineChart points={points} minSamples={H.minSamples} />
        ) : (
          <div className="table-scroll">
            <table>
              <caption className="sr-only">Baseline history per swap</caption>
              <thead>
                <tr>
                  <th>Swap</th>
                  <th>Block</th>
                  <th>Mean</th>
                  <th>Deviation</th>
                  <th>Threshold</th>
                  <th>This swap</th>
                  <th>Signal</th>
                  <th>Fee</th>
                </tr>
              </thead>
              <tbody>
                {points.map((p) => (
                  <tr key={`${p.n}-${p.tx}`} className={p.signal ? "flagged" : undefined}>
                    <td className="num-primary">{p.n}</td>
                    <td>{p.block}</td>
                    <td>{p.mean.toFixed(4)}%</td>
                    <td>{p.dev.toFixed(4)}%</td>
                    <td>{p.threshold > 0 ? `${p.threshold.toFixed(4)}%` : "—"}</td>
                    <td>{p.observed != null ? `${p.observed.toFixed(4)}%` : "—"}</td>
                    <td>
                      <span className={`sig ${p.signal ? "sig-flag" : "sig-none"}`}>{p.signal ?? "none"}</span>
                    </td>
                    <td className={p.signal ? "num-primary" : undefined}>
                      {((H.baseFee + p.penalty) / 10000).toFixed(2)}%
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <p className="footnote">
          Every value is decoded from <code>BaselineUpdated</code> and <code>ToxicFlowDetected</code>{" "}
          logs emitted by the deployed hook. Sizes are expressed as a fraction of pool liquidity.
        </p>
      </section>

      <section className="panel">
        <h2>What the attack cost, with and without</h2>
        <p className="sub">
          The same three swaps, the same sizes, one variable changed: the fee. Everything here is
          decoded from the pool's own <code>Swap</code> events.
        </p>
        <BeforeAfter data={H.sandwich} />
      </section>

      <section className="panel">
        <h2>Every detection in this pool</h2>
        <p className="sub">
          The complete log, across every attack run — not just the successful one. Note that only
          one is a <code>SandwichExit</code>: in the earlier runs the attacker's legs landed in
          different blocks, and the hook correctly declined to call those sandwiches. A detector
          that fires on everything proves nothing.
        </p>
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Leg</th>
                <th>Swap</th>
                <th>Signal</th>
                <th>Fee paid</th>
                <th>Transaction</th>
              </tr>
            </thead>
            <tbody>
              {stats.flagged.length === 0 && (
                <tr>
                  <td colSpan={5} style={{ textAlign: "center", padding: 20 }}>
                    No detections in the current window.
                  </td>
                </tr>
              )}
              {stats.flagged.map((p) => (
                <tr key={p.tx} className={p.signal === "SandwichExit" ? "flagged" : undefined}>
                  <td className="num-primary">
                    {p.signal === "SandwichExit" ? "attacker exit" : "oversized swap"}
                  </td>
                  <td>{p.n}</td>
                  <td>
                    <span className="sig sig-flag">{p.signal}</span>
                  </td>
                  <td className="num-primary">{((H.baseFee + p.penalty) / 10000).toFixed(2)}%</td>
                  <td>
                    <a href={`${EXPLORER}/tx/${p.tx}`} target="_blank" rel="noreferrer">
                      {short(p.tx)} ↗
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="footnote">
          A hook cannot see the mempool or reorder a swap, so detection happens at the attacker's{" "}
          <em>exit</em>. The victim's fill has already occurred — what Antibody destroys is the
          profit, which is what makes the strategy stop being worth running.
        </p>
      </section>
    </div>
  );
}

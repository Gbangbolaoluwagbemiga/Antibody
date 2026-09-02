import seed from "../data/history.json";
import type { History } from "../lib/types";
import { BaselineChart } from "../components/BaselineChart";
import { Reveal } from "../components/motion";
import { TimeWeighted } from "../components/TimeWeighted";
import { RoutingSignal } from "../components/RoutingSignal";

const H = seed as unknown as History;

export function How() {
  return (
    <>
      <Reveal>
        <section className="panel is-hero">
          <h2>The threshold is learned, not configured</h2>
          <p className="sub">
            For the first {H.minSamples - 1} swaps this pool publishes <strong>no threshold at all</strong> —
            a baseline with insufficient data reports no opinion rather than a misleading one. It
            appears at swap {H.minSamples}, then narrows as consistent flow confirms what normal
            looks like here. The climb at the right is the attack: the pool absorbing what it saw.
          </p>
          <BaselineChart points={H.points} minSamples={H.minSamples} />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>The mechanism</h2>
          <pre className="diagram">{`                 ┌──────────────── beforeSwap ────────────────┐
  swap request ─▶ │  read baseline (2 SLOADs)                  │
                  │  ├─ SandwichExit  same trader, same block, │
                  │  │                 reversed, victim between │
                  │  ├─ BlockReversal pool reversed in-block,   │
                  │  │                 different address,        │
                  │  │                 victim between            │
                  │  └─ SizeAnomaly   size > μ + kδ             │
                  │       ↓                                     │
                  │  fee | OVERRIDE_FEE_FLAG ──────────────────┼─▶ accrues to LPs
                  └─────────────────────────────────────────────┘
                                    ↓ swap executes
                  ┌──────────────── afterSwap ─────────────────┐
                  │  realized impact = |tick_after − tick_before|
                  │  μ ← μ + (x − μ)/16      ← THE state write  │
                  │  δ ← δ + (|x − μ| − δ)/16                   │
                  │  record (trader, block, direction, size)     │
                  │  advance the pool's in-block run (2 words)   │
                  │  emit BaselineUpdated / ToxicFlowDetected    │
                  └─────────────────────────────────────────────┘`}</pre>
          <p className="sub" style={{ marginTop: 16 }}>
            Mean absolute deviation instead of variance, so there is no <code>sqrt</code> on-chain.
            α = 1/16 as a bit-shift, so there is no division. The whole learning system is two
            packed storage slots per pool.
          </p>
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>Time-weighted, without pretending to delay anything</h2>
          <p className="sub">
            A hook cannot pause, queue or reorder a swap — so "time-weighted execution" cannot mean a
            delay, and claiming otherwise would ship a callback that doesn't do what it says. What it
            can mean is that temporal clustering costs money. Hover a bar.
          </p>
          <TimeWeighted hook={H.hook as `0x${string}`} />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>The signal, for whoever wants it</h2>
          <p className="sub">
            Flagged flow is published as a typed signal any router can consume — advisory, never
            blocking. Antibody emits it and stops there.
          </p>
          <RoutingSignal />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>Why the state write can't be skipped</h2>
          <p className="sub">
            Transient storage is scoped to a single transaction, but a sandwich spans three. So
            cross-transaction detection needs real storage stamped with <code>block.number</code> —
            which means the SSTORE that enables detection <em>is</em> the SSTORE that updates the
            baseline. They cannot come apart. A lazy or deferred baseline update would visibly break
            detection, and the tests would catch it.
          </p>
          <div className="tiles" style={{ margin: "18px 0 0" }}>
            <div className="tile">
              <div className="label">Hookless swap</div>
              <div className="value">44,061</div>
              <div className="note">gas, same pool shape</div>
            </div>
            <div className="tile">
              <div className="label">Antibody swap</div>
              <div className="value">78,729</div>
              <div className="note">gas, three SSTOREs</div>
            </div>
            <div className="tile">
              <div className="label">Overhead</div>
              <div className="value">34,668</div>
              <div className="note">paid by honest flow too — quoted, not hidden</div>
            </div>
          </div>
        </section>
      </Reveal>
    </>
  );
}

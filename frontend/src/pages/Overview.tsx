import seed from "../data/history.json";
import type { History, Point } from "../lib/types";
import { TwoPools } from "../components/TwoPools";
import { Immunity } from "../components/Immunity";
import { Categories } from "../components/Categories";
import { Ticker, Reveal } from "../components/motion";
import { Link } from "react-router-dom";

const H = seed as unknown as History;

export function Overview() {
  const a = H.points[H.points.length - 1];
  const b = (H.poolB.points ?? [])[(H.poolB.points ?? []).length - 1];
  const sandwich = H.points.find((p) => p.signal === "SandwichExit");

  return (
    <>
      <div className="tiles">
        <div className="tile">
          <div className="label">Pool A boundary</div>
          <div className="value"><Ticker value={a.threshold} decimals={3} suffix="%" /></div>
          <div className="note">learned from {a.n} swaps of its own flow</div>
        </div>
        <div className="tile">
          <div className="label">Pool B boundary</div>
          <div className="value"><Ticker value={b?.threshold ?? 0} decimals={3} suffix="%" /></div>
          <div className="note">same hook · different flow · different answer</div>
        </div>
        <div className="tile is-flagged">
          <div className="label">Attacker's exit paid</div>
          <div className="value">
            <Ticker value={(H.baseFee + (sandwich?.penalty ?? 0)) / 10000} decimals={2} suffix="%" />
          </div>
          <div className="note">16.7× base · routed to liquidity providers</div>
        </div>
        <div className="tile">
          <div className="label">False positives</div>
          <div className="value"><Ticker value={0} decimals={0} /></div>
          <div className="note">across 26 ordinary calibration swaps</div>
        </div>
      </div>

      <Reveal>
        <section className="panel is-hero">
          <h2>Nobody configured these numbers</h2>
          <p className="sub">
            Most MEV defenses are a rule set someone tuned: a threshold, a size cap, an allowlist.
            They work until the market moves. Antibody has no threshold to tune — each pool derives
            its own from an exponentially-weighted mean of trade-size-to-liquidity plus a deviation
            band, updated in <code>afterSwap</code>, in storage, on every swap.
          </p>
          <TwoPools
            pools={[
              {
                label: "Pool A",
                poolId: H.poolA.poolId,
                regime: H.poolA.regime,
                accent: "var(--series-threshold)",
                points: H.points as Point[],
                story:
                  "Saw steady flow, then absorbed a sandwich attack. Its band widened to account for what it had just experienced.",
              },
              {
                label: "Pool B",
                poolId: H.poolB.poolId,
                regime: H.poolB.regime,
                accent: "var(--series-mean)",
                points: (H.poolB.points ?? []) as Point[],
                story:
                  "Saw only consistent flow, ten times larger per swap. Its band stayed tight because nothing surprised it.",
              },
            ]}
          />
          <p className="footnote">
            Both pools are served by the same deployed contract at the same address. Read live from
            Unichain Sepolia. <Link to="/try">Price your own swap against them →</Link>
          </p>
        </section>
      </Reveal>

      <Reveal>
        <section className="panel is-hero">
          <h2>Attack one pool, every pool remembers</h2>
          <p className="sub">
            A per-pool baseline has an obvious hole: attack pool A, get priced, move to pool B. So a
            confirmed sandwich exit is recorded against the <em>trader</em>, held by the hook rather
            than by any pool. Below are two addresses quoted against pool B — which has never seen
            either of them — for the same swap, right now.
          </p>
          <Immunity
            hook={H.hook as `0x${string}`}
            poolB={H.poolB.poolId as `0x${string}`}
            attacker={H.immunity.attacker as `0x${string}`}
            attackBlock={H.immunity.attackBlock}
            window={H.immunity.window}
            baseFee={H.baseFee}
          />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>What it does, and what it doesn't</h2>
          <p className="sub">
            A hook cannot see the mempool, and cannot pause, queue, or reorder a swap. So the honest
            claim is narrow and defensible:
          </p>
          <blockquote className="pull">
            Antibody makes sandwich attacks unprofitable. It does not make them impossible.
          </blockquote>
          <p className="sub">
            Detection happens at the attacker's <em>exit</em> — the closing leg, the moment the
            pattern becomes visible on-chain. The victim's fill has already happened. What gets
            destroyed is the profit, which is what makes the strategy stop being worth running.{" "}
            <Link to="/attack">See what the attack actually cost →</Link>
          </p>
        </section>
      </Reveal>
      <Reveal>
        <section className="panel">
          <h2>What this claims, and where to check it</h2>
          <p className="sub">
            Four of the five UHI10 theme categories, each pointing at the thing that backs it. The
            fifth is listed as deliberately skipped rather than quietly omitted — a claimed category
            with nothing behind it is worse than not claiming it.
          </p>
          <Categories />
        </section>
      </Reveal>

    </>
  );
}
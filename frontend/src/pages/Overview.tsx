import seed from "../data/history.json";
import type { History, Point } from "../lib/types";
import { TwoPools } from "../components/TwoPools";
import { Immunity } from "../components/Immunity";
import { Categories } from "../components/Categories";
import { Vaccination } from "../components/Vaccination";
import { MainnetReplay } from "../components/MainnetReplay";
import { LiquidityCase } from "../components/LiquidityCase";
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
          <div className="value">
            <Ticker value={H.falsePositives.flaggedAsSandwich} decimals={0} />
          </div>
          <div className="note">
            across {H.falsePositives.ordinarySwaps} ordinary swaps on both pools
          </div>
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
                  `Earned its baseline from scratch over ${H.points.length} swaps, then absorbed two sandwich attacks. Its band widened to account for what it had just experienced.`,
              },
              {
                label: "Pool B",
                poolId: H.poolB.poolId,
                regime: H.poolB.regime,
                accent: "var(--series-mean)",
                points: (H.poolB.points ?? []) as Point[],
                story:
                  "Opened with pool A's baseline inherited — protected before it had traded once. Its own flow runs small against deeper liquidity, so it pulled the band back down below the pool it inherited from.",
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
          <h2>A new pool is not defenceless</h2>
          <p className="sub">
            A learned threshold has an obvious hole, and publishing the design is what makes it
            targetable: the detector stays silent until a pool has history, so an attacker waits for
            a fresh pool. A pool trading a pair an established sibling already characterised does
            not have to wait — it opens with that sibling's baseline.
          </p>
          <Vaccination
            donor={H.vaccination.donor}
            recipient={H.vaccination.recipient}
            block={H.vaccination.block}
            tx={H.vaccination.tx}
            threshold={H.vaccination.threshold}
            baseFee={H.baseFee}
            unprotectedFee={H.baseFee}
            protectedFee={H.maxTotalFee}
          />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>Why a pool would want this</h2>
          <p className="sub">
            Every other panel here explains what the hook does. This one answers the question a pool
            creator asks first — what is in it for me — and states the trade rather than only the
            upside.
          </p>
          <LiquidityCase {...H.liquidityCase} baseFee={H.baseFee} />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>Measured against real attacks, not staged ones</h2>
          <p className="sub">
            Every other demonstration here is an attack I staged against a detector I designed, and
            a sceptical reader is right to discount that. So this one uses data I did not author:
            live Uniswap v3 blocks on Ethereum mainnet, scanned for the mechanical signature of a
            sandwich, replayed against the hook. The result changed the design.
          </p>
          <MainnetReplay {...H.mainnetReplay} precision={H.mainnetPrecision} />
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
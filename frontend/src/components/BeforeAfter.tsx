import type { Sandwich } from "../lib/types";

/**
 * What the sandwich actually cost, with Antibody and without it.
 *
 * Every figure is decoded from the PoolManager's own `Swap` events for block 59767385 — the
 * amounts and the fee the pool applied to each leg. Nothing is modelled. The counterfactual is the
 * one thing not measured, and it is deliberately the *narrowest* possible one: the same three
 * swaps, at the same sizes, paying the pool's 0.30% base fee instead of the fee Antibody set.
 * It does not assume the attacker would have sized differently, or that the price path would have
 * been identical — it isolates exactly one variable, the fee.
 */

const EXPLORER = "https://sepolia.uniscan.xyz";
const pct = (pips: number) => `${(pips / 10000).toFixed(2)}%`;
const short = (s: string) => `${s.slice(0, 8)}…`;

export function BeforeAfter({ data }: { data: Sandwich }) {
  const extra = data.feesWithAntibody - data.feesAtBaseOnly;
  const multiple = data.feesWithAntibody / data.feesAtBaseOnly;

  // The attacker gained token0 and lost token1. At the pool's ~1:1 initialisation these net out
  // to a loss, and that loss is within a rounding of the fee Antibody added.
  const net = data.attackerNet.t0 + data.attackerNet.t1;
  const netWithoutAntibody = net + extra;

  return (
    <>
      <div className="ba-grid">
        <div className="ba-col">
          <div className="ba-head">Without Antibody</div>
          <div className="ba-figure">{data.feesAtBaseOnly.toFixed(3)}</div>
          <div className="ba-cap">paid in fees on the attacker's two legs</div>
          <div className="ba-detail">
            <div className="ba-row">
              <span>fee per leg</span>
              <span>{pct(data.baseFee)}</span>
            </div>
            <div className="ba-row">
              <span>attacker net</span>
              <span className={netWithoutAntibody >= 0 ? "pos" : "neg"}>
                {netWithoutAntibody >= 0 ? "+" : ""}
                {netWithoutAntibody.toFixed(3)}
              </span>
            </div>
            <div className="ba-row">
              <span>to LPs</span>
              <span>{data.feesAtBaseOnly.toFixed(3)}</span>
            </div>
          </div>
        </div>

        <div className="ba-arrow" aria-hidden="true">
          <svg viewBox="0 0 40 24" width="40" height="24">
            <path d="M2 12h32m0 0-7-6m7 6-7 6" fill="none" stroke="var(--text-muted)" strokeWidth="1.6"
                  strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </div>

        <div className="ba-col is-primary">
          <div className="ba-head">With Antibody</div>
          <div className="ba-figure">{data.feesWithAntibody.toFixed(3)}</div>
          <div className="ba-cap">paid in fees on the attacker's two legs</div>
          <div className="ba-detail">
            <div className="ba-row">
              <span>fee per leg</span>
              <span>
                {pct(data.legs[0].fee)} · {pct(data.legs[2].fee)}
              </span>
            </div>
            <div className="ba-row">
              <span>attacker net</span>
              <span className={net >= 0 ? "pos" : "neg"}>
                {net >= 0 ? "+" : ""}
                {net.toFixed(3)}
              </span>
            </div>
            <div className="ba-row">
              <span>to LPs</span>
              <span className="pos">+{data.feesWithAntibody.toFixed(3)}</span>
            </div>
          </div>
        </div>
      </div>

      <div className="ba-verdict">
        <strong>{multiple.toFixed(1)}× the fee</strong> on the attacker's legs —{" "}
        <strong>{extra.toFixed(3)}</strong> that went to liquidity providers instead of staying with
        the attacker. The victim paid the base fee and nothing more.
      </div>

      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Leg</th>
              <th>In</th>
              <th>Out</th>
              <th>Fee applied</th>
              <th>Transaction</th>
            </tr>
          </thead>
          <tbody>
            {data.legs.map((l) => (
              <tr key={l.tx} className={l.actor === "attacker" ? "flagged" : undefined}>
                <td className="num-primary">
                  {l.role}
                  {l.actor === "victim" && <span className="ba-tag">untouched</span>}
                </td>
                <td>
                  {l.amountIn.toFixed(4)} {l.tokenIn}
                </td>
                <td>
                  {l.amountOut.toFixed(4)} {l.tokenOut}
                </td>
                <td className={l.fee > data.baseFee ? "num-primary" : undefined}>{pct(l.fee)}</td>
                <td>
                  <a href={`${EXPLORER}/tx/${l.tx}`} target="_blank" rel="noreferrer">
                    {short(l.tx)} ↗
                  </a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="footnote">
        Amounts and applied fees are decoded from the PoolManager's <code>Swap</code> events in block{" "}
        {data.block}. The counterfactual holds every variable fixed except the fee. Note the victim's
        trade here was sized inside the calibrated band on purpose, so the raw extraction available
        was small — the deterrent is that the cost scales with the <em>attacker's</em> own leg size,
        not with how much they manage to extract.
      </p>
    </>
  );
}

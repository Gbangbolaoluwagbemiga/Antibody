import seed from "../data/history.json";
import type { History } from "../lib/types";
import { BeforeAfter } from "../components/BeforeAfter";
import { Reveal } from "../components/motion";
import { unichainSepolia } from "../lib/chain";

const H = seed as unknown as History;
const EXPLORER = unichainSepolia.blockExplorers.default.url;
const short = (s: string) => `${s.slice(0, 8)}…`;

export function Attack() {
  const flagged = H.points.filter((p) => p.signal);

  return (
    <>
      <Reveal>
        <section className="panel is-hero">
          <h2>What the attack cost, with and without</h2>
          <p className="sub">
            A real sandwich, all three legs in block {H.sandwich.block}. The same three swaps at the
            same sizes, one variable changed: the fee. Everything here is decoded from the
            PoolManager's own <code>Swap</code> events.
          </p>
          <BeforeAfter data={H.sandwich} />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>Every detection in this pool</h2>
          <p className="sub">
            The complete log, across every attack run — not just the successful one. Only one is a{" "}
            <code>SandwichExit</code>: in the earlier runs the attacker's legs landed in different
            blocks, and the hook correctly declined to call those sandwiches. A detector that fires
            on everything proves nothing.
          </p>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Leg</th><th>Swap</th><th>Signal</th><th>Fee paid</th><th>Transaction</th>
                </tr>
              </thead>
              <tbody>
                {flagged.map((p) => (
                  <tr key={p.tx} className={p.signal === "SandwichExit" ? "flagged" : undefined}>
                    <td className="num-primary">
                      {p.signal === "SandwichExit" ? "attacker exit" : "oversized swap"}
                    </td>
                    <td>{p.n}</td>
                    <td><span className="sig sig-flag">{p.signal}</span></td>
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
        </section>
      </Reveal>
    </>
  );
}

import seed from "../data/history.json";
import type { History } from "../lib/types";
import { BeforeAfter } from "../components/BeforeAfter";
import { Reveal } from "../components/motion";
import { AttackButton } from "../components/AttackButton";
import { DetectionLog } from "../components/DetectionLog";

const H = seed as unknown as History;

export function Attack() {
  const flagged = H.points.filter((p) => p.signal);

  return (
    <>
      <Reveal>
        <section className="panel is-hero">
          <h2>Attack it yourself</h2>
          <p className="sub">
            Fires three real transactions at the live pool — front-run, victim, exit — and reports
            what the hook did. Co-location is probable, not guaranteed: a public testnet has no
            bundle endpoint, so if the legs split across blocks the hook correctly refuses to call it
            a sandwich, and that is reported too.
          </p>
          <AttackButton baseFee={H.baseFee} />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
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
          <DetectionLog
            hook={H.hook as `0x${string}`}
            pools={[
              { id: H.poolA.poolId as `0x${string}`, label: "pool A" },
              { id: H.poolB.poolId as `0x${string}`, label: "pool B" },
            ]}
            baseFee={H.baseFee}
            fallback={flagged}
          />
        </section>
      </Reveal>
    </>
  );
}

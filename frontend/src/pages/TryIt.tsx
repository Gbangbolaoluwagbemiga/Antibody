import seed from "../data/history.json";
import type { History } from "../lib/types";
import { QuoteProbe } from "../components/QuoteProbe";
import { Reveal } from "../components/motion";

const H = seed as unknown as History;

export function TryIt() {
  return (
    <>
      <Reveal>
        <section className="panel is-hero">
          <h2>Price a swap against pool A</h2>
          <p className="sub">
            Drag the size. The fee comes straight from the deployed hook's <code>quote()</code> view
            — the same assessment the swap path runs, read live from Unichain Sepolia. It stays
            ordinary right up to the boundary this pool computed for itself, and then it doesn't. No
            wallet, no gas: it's a view function.
          </p>
          <QuoteProbe hook={H.hook as `0x${string}`} poolId={H.poolA.poolId as `0x${string}`}
                      baseFee={H.baseFee} maxTotalFee={H.maxTotalFee} />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>The same swap against pool B</h2>
          <p className="sub">
            Identical contract, identical code path — but this pool learned a different boundary
            from different flow. A trade that is unremarkable in one pool is an anomaly in the
            other, and no per-pool configuration exists to explain the difference.
          </p>
          <QuoteProbe hook={H.hook as `0x${string}`} poolId={H.poolB.poolId as `0x${string}`}
                      baseFee={H.baseFee} maxTotalFee={H.maxTotalFee} />
        </section>
      </Reveal>
    </>
  );
}

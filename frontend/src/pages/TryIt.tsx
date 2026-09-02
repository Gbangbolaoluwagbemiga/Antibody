import seed from "../data/history.json";
import type { History } from "../lib/types";
import { QuoteProbe } from "../components/QuoteProbe";
import { Reveal } from "../components/motion";
import { WalletSwap } from "../components/WalletSwap";
import { LiveFeed } from "../components/LiveFeed";

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
      <Reveal>
        <section className="panel">
          <h2>Swap it yourself — against pool A</h2>
          <p className="sub">
            Reading a quote proves the hook has an opinion. Executing a swap proves the chain
            enforces it — the fee on your receipt is set by <code>beforeSwap</code>, and nothing on
            this page can influence it. The demo tokens mint freely, so you can fund yourself in one
            click.
          </p>
          <p className="sub">
            <strong>This swaps against pool A</strong>, whose boundary is the first number on this
            page — not pool B's directly above. They are different pools with different learned
            boundaries, so a size that looks unremarkable against one can be an anomaly against the
            other. That is the whole point of the two panels, and it is easy to trip over here.
          </p>
          <WalletSwap
            hook={H.hook as `0x${string}`}
            token0={"0x2975200DA18f21bF8ecE746Bed6281e4B373D548"}
            token1={"0x5906F35B86A6AC0281A5655933eE37253aA42ef4"}
            tickSpacing={H.poolA.tickSpacing}
          />
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>Swaps landing now</h2>
          <p className="sub">
            Both pools, newest first, polled from chain. Anything the hook flagged is marked with the
            signal that fired and the fee it drew.
          </p>
          <LiveFeed
            hook={H.hook as `0x${string}`}
            pools={[
              { id: H.poolA.poolId as `0x${string}`, label: "pool A" },
              { id: H.poolB.poolId as `0x${string}`, label: "pool B" },
            ]}
          />
        </section>
      </Reveal>
    </>
  );
}

import seed from "../data/history.json";
import type { History } from "../lib/types";
import { Reveal } from "../components/motion";
import { unichainSepolia } from "../lib/chain";

const H = seed as unknown as History;
const EX = unichainSepolia.blockExplorers.default.url;

const ADDRESSES: Array<[string, string]> = [
  ["AntibodyHook", H.hook],
  ["Pool A", H.poolA.poolId],
  ["Pool B", H.poolB.poolId],
  ["Demo token 0 (ABDA)", "0x2975200DA18f21bF8ecE746Bed6281e4B373D548"],
  ["Demo token 1 (ABDB)", "0x5906F35B86A6AC0281A5655933eE37253aA42ef4"],
  ["v4 PoolManager", "0x00B036B58a818B1BC34d502D3fE730Db729e62AC"],
];

const LIMITS = [
  ["The statistical detector can be desensitised.", "An attacker repeatedly trading large sizes drags the mean and deviation upward, widening what counts as normal. At α = 1/16 that costs roughly 16 swaps of sustained penalty. It does not defeat sandwich detection — the structural signals consult no baseline at all."],
  ["SizeAnomaly does not distinguish attacker from victim.", "A sandwich victim making an unusually large trade pays the anomaly fee too. Only the structural detectors tell the two apart."],
  ["Detection is at the exit, not the entry.", "The victim's fill has already occurred. Antibody makes sandwiching unprofitable, not impossible."],
  ["Multi-EOA attackers draw three quarters, not the ceiling.", "A gated reversal under two addresses is inference rather than proof of common control, so it is priced below same-origin on purpose."],
  ["It catches 35 of 39 real sandwiches, not 39 of 39.", "Requiring a victim in between took false positives on ordinary mainnet blocks from 133 of 322 — 41% — down to 0, and cost 4 detections. Those 5 are unrecoverable by a hook: afterSwap sees one swap and two storage words, not the whole block. The specific gap is when the run's opener is also the party in the middle — there is no third slot for them, so the exit reads as the victim closing their own position."],
  ["Cross-pool memory does not reach a rotating attacker.", "Resolving the senders behind 25 real mainnet sandwiches showed all 25 exits used a fresh address, and no entry/exit pair ever repeated. Address rotation is standard practice, so the memory raises the cost of repeat extraction rather than stopping the sophisticated case. The structural signals carry that, because they consult no identity at all."],
  ["Identity is tx.origin.", "A heuristic grouping key, never an authorization check — nothing is granted on it. Account-abstraction bundles do not resolve to a stable identity; the pool-level detector covers that gap."],
];

export function Verify() {
  return (
    <>
      <Reveal>
        <section className="panel is-hero">
          <h2>Everything is on chain</h2>
          <p className="sub">
            No claim on this site is unverifiable. Every address below is live on Unichain Sepolia.
          </p>
          <div className="table-scroll">
            <table>
              <thead><tr><th>What</th><th>Address</th></tr></thead>
              <tbody>
                {ADDRESSES.map(([label, addr]) => (
                  <tr key={addr}>
                    <td className="num-primary">{label}</td>
                    <td>
                      {label.startsWith("Pool") ? (
                        <code>{addr}</code>
                      ) : (
                        <a href={`${EX}/address/${addr}`} target="_blank" rel="noreferrer">{addr} ↗</a>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="footnote">
            The hook address encodes its permissions in its low bits: <code>0x…a0c0 &amp; 0x3FFF = 0x20C0</code>{" "}
            = BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP, matching <code>getHookPermissions()</code>.
          </p>
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>Known limitations</h2>
          <p className="sub">
            Stated here rather than left for someone to discover. Each one is a real property of the
            design, not a bug awaiting a fix.
          </p>
          <dl className="limits">
            {LIMITS.map(([head, body]) => (
              <div key={head}>
                <dt>{head}</dt>
                <dd>{body}</dd>
              </div>
            ))}
          </dl>
        </section>
      </Reveal>

      <Reveal>
        <section className="panel">
          <h2>What running it on a real chain caught</h2>
          <p className="sub">
            Four defects the test suite had not. The most important: an earlier build classified{" "}
            <strong>23 of 23</strong> ordinary calibration swaps as sandwiches.{" "}
            <code>SandwichExit</code> was defined as <em>same trader, same block, opposite
            direction</em> — which is also what a rebalancing market maker or a multi-hop route looks
            like. A sandwich is defined by its victim, so the rule now requires a third party to have
            traded in between.
          </p>
          <p className="sub">
            The tests missed it because every calibration helper advanced a block between swaps, so
            the same-block case never arose. Forty-three passing tests were evidence about the cases
            that had been constructed, not about the one that hadn't.
          </p>
          <p className="sub">
            The fourth defect survived six deployments and was found by asking a question, not by a
            test: <em>how often does the detector fire on nothing?</em> Recall had been measured — 25
            of 25 real mainnet sandwiches — and precision never had. Replayed against 322 real
            mainnet blocks containing trading and no sandwich,{" "}
            <code>BlockReversal</code> as shipped fired on <strong>133 of them</strong> — 41%. More than
            three quarters of everything it flagged was innocent, because "the pool reversed direction under
            a different address" is also a plain description of two arbitrageurs crossing. It is the
            same defect as the 23-of-23 above, wearing a different variable name — and it is why the
            same repair, requiring a victim in between, is now applied to both detectors.
          </p>
        </section>
      </Reveal>
    </>
  );
}

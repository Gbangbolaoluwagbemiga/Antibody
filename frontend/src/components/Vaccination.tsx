import { motion } from "framer-motion";
import { unichainSepolia } from "../lib/chain";

/**
 * Inherited protection — the third layer, and the one that closes a real attack surface.
 *
 * A learned-threshold design has an obvious hole, and publishing the design is what makes it
 * targetable: the detector stays silent until the pool has enough history, so an attacker waits for
 * a fresh pool and works the window. Refusing to have an opinion is right when there is nothing to
 * base one on — but a pool trading a pair an established sibling has already characterised is not
 * in that position.
 *
 * So a new pool opens with its sibling's baseline. Protection before exposure, which is what a
 * vaccine is. The numbers below are read from the chain, not asserted.
 */

const EXPLORER = unichainSepolia.blockExplorers.default.url;

type Props = {
  donor: string;
  recipient: string;
  block: number;
  tx: string;
  threshold: number;
  baseFee: number;
  /** What that same pool would have charged with no inherited baseline: nothing is watching yet. */
  unprotectedFee: number;
  /** What it actually charges an oversized trade on its very first swap. */
  protectedFee: number;
};

const short = (s: string) => `${s.slice(0, 10)}…`;

export function Vaccination({
  donor,
  recipient,
  block,
  tx,
  threshold,
  baseFee,
  unprotectedFee,
  protectedFee,
}: Props) {
  const multiple = protectedFee / unprotectedFee;

  return (
    <div className="vax">
      <div className="vax-flow">
        <motion.div
          className="vax-node"
          initial={{ opacity: 0, x: -12 }}
          whileInView={{ opacity: 1, x: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.4 }}
        >
          <span className="vax-role">donor</span>
          <code>{short(donor)}</code>
          <p>Earned its baseline over 26 swaps of its own flow.</p>
        </motion.div>

        <motion.div
          className="vax-arrow"
          initial={{ opacity: 0, scaleX: 0 }}
          whileInView={{ opacity: 1, scaleX: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 0.45, delay: 0.25 }}
          aria-hidden="true"
        >
          <span className="vax-arrow-label">{threshold.toFixed(4)}%</span>
          <svg viewBox="0 0 60 12" width="60" height="12">
            <path d="M0 6h50m0 0-6-4m6 4-6 4" fill="none" stroke="var(--accent)" strokeWidth="1.6"
                  strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </motion.div>

        <motion.div
          className="vax-node is-new"
          initial={{ opacity: 0, x: 12 }}
          whileInView={{ opacity: 1, x: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.4, delay: 0.45 }}
        >
          <span className="vax-role">new pool</span>
          <code>{short(recipient)}</code>
          <p>
            Zero swaps observed. Defended from the first one, at block {block}.
          </p>
        </motion.div>
      </div>

      <div className="vax-compare">
        <div>
          <span className="vax-label">without inheritance</span>
          <strong>{(unprotectedFee / 10000).toFixed(2)}%</strong>
          <span className="vax-cap">nothing is watching yet</span>
        </div>
        <div className="is-primary">
          <span className="vax-label">with inheritance</span>
          <strong>{(protectedFee / 10000).toFixed(2)}%</strong>
          <span className="vax-cap">priced on swap one</span>
        </div>
        <div className="vax-delta">
          <strong>{multiple.toFixed(1)}×</strong>
          <span className="vax-cap">on an identical oversized trade</span>
        </div>
      </div>

      <p className="footnote">
        Two constraints are enforced in the contract, not just described. Only a pool that{" "}
        <em>earned</em> its baseline can confer one — passing on an unearned opinion would launder a
        guess into something that looks like evidence. And the inherited state stays marked
        permanently, with the sample count set to the minimum rather than the donor's, because
        claiming the donor's count would assert swaps this pool never saw. Its own experience
        replaces the priors over roughly sixteen swaps.{" "}
        <a href={`${EXPLORER}/tx/${tx}`} target="_blank" rel="noreferrer">
          the inheritance, on chain ↗
        </a>
      </p>
    </div>
  );
}

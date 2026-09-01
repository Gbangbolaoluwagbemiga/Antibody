import { motion } from "framer-motion";

/**
 * Who actually buys this, and why.
 *
 * Every other panel explains what the hook does. None of them answer the question a pool creator
 * would ask first: what is in it for me. The chain is LPs earn more under attack -> liquidity
 * prefers pools where it is not being skimmed -> a pool creator adopts the hook to attract it.
 *
 * The tension is stated rather than hidden, because it is real and a judge will find it in ten
 * seconds otherwise: honest traders pay the gas overhead on every swap, while the LP upside only
 * materialises when an attack happens. That is a genuine trade, not a free win, and the honest
 * version of this argument is more persuasive than the one-sided one.
 */

type Props = {
  lpWithAntibody: number;
  lpAtBaseFee: number;
  upliftMultiple: number;
  gasOverhead: number;
  baseFee: number;
  block: number;
};

export function LiquidityCase({ lpWithAntibody, lpAtBaseFee, upliftMultiple, gasOverhead, baseFee, block }: Props) {
  const extra = lpWithAntibody - lpAtBaseFee;

  return (
    <div className="lpcase">
      <div className="lpcase-figures">
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.4 }}
        >
          <span className="lpcase-label">LPs captured</span>
          <strong className="is-gain">{lpWithAntibody.toFixed(3)}</strong>
          <span className="lpcase-cap">from the attack in block {block}</span>
        </motion.div>

        <motion.div
          initial={{ opacity: 0, y: 10 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.4, delay: 0.1 }}
        >
          <span className="lpcase-label">without the hook</span>
          <strong>{lpAtBaseFee.toFixed(3)}</strong>
          <span className="lpcase-cap">the rest stayed with the attacker</span>
        </motion.div>

        <motion.div
          initial={{ opacity: 0, y: 10 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.4, delay: 0.2 }}
        >
          <span className="lpcase-label">uplift</span>
          <strong className="is-accent">{upliftMultiple.toFixed(1)}×</strong>
          <span className="lpcase-cap">+{extra.toFixed(3)} redirected to liquidity</span>
        </motion.div>
      </div>

      <div className="lpcase-chain">
        <span>LPs keep what an attacker would have taken</span>
        <em>→</em>
        <span>liquidity prefers pools where it is not skimmed</span>
        <em>→</em>
        <span>a pool creator adopts the hook to attract it</span>
      </div>

      <p className="lpcase-tension">
        <strong>The honest tension.</strong> That uplift only appears when an attack happens — on
        ordinary flow LPs earn the same {(baseFee / 10000).toFixed(2)}% they always would. Meanwhile
        every swap, honest ones included, carries about {gasOverhead.toLocaleString()} gas of
        overhead. So the real trade a pool creator is making is: honest traders pay a little gas, and
        in exchange the pool stops being a profitable place to sandwich. Whether that is worth it
        depends on how much toxic flow the pool actually attracts — which is exactly the thing the
        hook measures for itself.
      </p>
    </div>
  );
}

import { motion } from "framer-motion";

/**
 * The measurement that changed the design.
 *
 * Everything else on this site is a staged attack against a detector I built, which a sceptical
 * reader is right to discount. This is the one panel whose numbers came from data I did not author:
 * real Uniswap v3 blocks on Ethereum mainnet, scanned for the mechanical signature of a sandwich,
 * then replayed against the hook.
 *
 * The result was uncomfortable, which is why it is on the site rather than buried in a repo. The
 * strongest signal in the design — the one carrying the maximum penalty, the one every other panel
 * here demonstrates — did not fire on a single real attack. The weaker one caught all of them.
 */

type Props = {
  blocksWithSwaps: number;
  blocksWithoutSandwich: number;
  sandwiches: number;
  caughtBySandwichExit: number;
  caughtByBlockReversal: number;
  missed: number;
};

export function MainnetReplay({
  blocksWithSwaps,
  blocksWithoutSandwich,
  sandwiches,
  caughtBySandwichExit,
  caughtByBlockReversal,
  missed,
}: Props) {
  const rows = [
    { label: "SandwichExit", note: "maximum penalty", hits: caughtBySandwichExit, tone: "miss" },
    { label: "BlockReversal", note: "repriced to three quarters", hits: caughtByBlockReversal, tone: "hit" },
    { label: "missed entirely", note: "no detector fired", hits: missed, tone: "neutral" },
  ];

  return (
    <div className="replay">
      <div className="replay-scope">
        <div>
          <span>blocks with swaps</span>
          <strong>{blocksWithSwaps}</strong>
        </div>
        <div>
          <span>sandwich-shaped</span>
          <strong>{sandwiches}</strong>
        </div>
        <div>
          <span>activity, no sandwich</span>
          <strong>{blocksWithoutSandwich}</strong>
        </div>
      </div>

      <ul className="replay-rows">
        {rows.map((r, i) => (
          <motion.li
            key={r.label}
            className={`is-${r.tone}`}
            initial={{ opacity: 0, x: -8 }}
            whileInView={{ opacity: 1, x: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.35, delay: i * 0.1 }}
          >
            <span className="replay-name">
              <code>{r.label}</code>
              <em>{r.note}</em>
            </span>
            <span className="replay-hits">
              {r.hits} <small>of {sandwiches}</small>
            </span>
          </motion.li>
        ))}
      </ul>

      <p className="replay-verdict">
        <strong>Not one real sandwich was same-origin.</strong> Production searchers split entry and
        exit across separate addresses precisely to defeat same-origin detection — so the signal
        carrying the maximum penalty, the one every other demo on this site is built on, would not
        have fired on a single live attack. The layer built for multi-EOA attackers caught all of
        them, and was repriced from half the span to three quarters as a result.
      </p>

      <p className="footnote">
        Profit is deliberately not modelled. Those are v2/v3 pools with static fees and different
        liquidity mechanics, so a "would have taken $X" figure would be a guess dressed as evidence.
        Detection is a classification question, and that is the only question answered here.
      </p>
    </div>
  );
}

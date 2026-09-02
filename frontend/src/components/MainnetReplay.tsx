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
  precision: {
    ordinaryBlocks: number;
    sandwichBlocks: number;
    firedOnOrdinary: number;
    caughtSandwich: number;
    beforeGateFiredOnOrdinary: number;
    beforeGateCaughtSandwich: number;
  };
};

export function MainnetReplay({
  blocksWithSwaps,
  blocksWithoutSandwich,
  sandwiches,
  caughtBySandwichExit,
  caughtByBlockReversal,
  missed,
  precision,
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

      <div className="precision">
        <h3>Then the question nobody had asked: how often does it fire on nothing?</h3>
        <p className="sub">
          Catching 25 of 25 is recall, and recall alone is worth nothing — a detector that fires on
          every swap also scores 25 of 25. Replaying {precision.ordinaryBlocks} real mainnet blocks
          that contained trading and <em>no</em> sandwich answered the other half.
        </p>
        <p className="sub caveat">
          <strong>These are two different measurements, not a before and after.</strong> The panel
          above replays each attack as an isolated three-swap block, which tests whether the detector
          recognises the shape. The numbers below replay real blocks with <em>all</em> their swaps
          interleaved — three to eleven of them — which is the condition it actually faces. Different
          scans, no overlap. Recall there is {precision.caughtSandwich} of {precision.sandwichBlocks},
          not 25 of 25, and that lower figure is the honest one: the idealized replay flatters the
          detector by handing it a textbook sandwich with nothing else in the block.
        </p>

        <div className="precision-grid">
          <div className="precision-col is-before">
            <div className="precision-head">
              shipped for six deployments
              <em>reversal by any different address</em>
            </div>
            <div className="precision-stat">
              <strong>{precision.beforeGateFiredOnOrdinary}</strong>
              <span>of {precision.ordinaryBlocks} ordinary blocks flagged</span>
            </div>
            <div className="precision-foot">
              caught {precision.beforeGateCaughtSandwich}/{precision.sandwichBlocks} ·{" "}
              <b>
                {Math.round(
                  (precision.beforeGateCaughtSandwich /
                    (precision.beforeGateCaughtSandwich + precision.beforeGateFiredOnOrdinary)) *
                    100,
                )}
                % precision
              </b>
            </div>
          </div>

          <div className="precision-col is-after">
            <div className="precision-head">
              deployed now
              <em>…and a third party must have traded in between</em>
            </div>
            <div className="precision-stat">
              <strong>{precision.firedOnOrdinary}</strong>
              <span>of {precision.ordinaryBlocks} ordinary blocks flagged</span>
            </div>
            <div className="precision-foot">
              caught {precision.caughtSandwich}/{precision.sandwichBlocks} ·{" "}
              <b>100% precision</b>
            </div>
          </div>
        </div>

        <p className="replay-verdict">
          <strong>Three fifths of what it flagged was innocent.</strong> "The pool reversed direction
          under a different address" is also a plain description of two arbitrageurs crossing in a
          busy block — the same defect as the 23-of-23 false positives this project already found
          once, wearing a different variable name. Requiring a victim in between removed all{" "}
          {precision.beforeGateFiredOnOrdinary} false positives and cost{" "}
          {precision.beforeGateCaughtSandwich - precision.caughtSandwich} of{" "}
          {precision.sandwichBlocks} detections, which a hook cannot recover:{" "}
          <code>afterSwap</code> sees one swap and two storage words, not the whole block. That trade
          was taken deliberately. Overcharging an innocent trader is the failure this design exists
          to argue against.
        </p>
      </div>

      <p className="footnote">
        The harness is <code>MEVBench</code>, and it is deliberately hook-agnostic: inherit it,
        implement three functions, and it replays real Ethereum blocks against any v4 hook and
        reports recall, precision and false-positive rate. Antibody is simply its first caller — a
        benchmark only its author can run is not a benchmark. Every MEV hook reports "it caught N
        attacks"; almost none report how often they fire on nothing.
      </p>

      <p className="footnote">
        Profit is deliberately not modelled. Those are v2/v3 pools with static fees and different
        liquidity mechanics, so a "would have taken $X" figure would be a guess dressed as evidence.
        Detection is a classification question, and that is the only question answered here.
      </p>
    </div>
  );
}

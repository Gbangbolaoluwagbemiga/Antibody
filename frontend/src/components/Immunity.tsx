import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import { quoteSwap, unichainSepolia } from "../lib/chain";

/**
 * The payoff of the whole design, shown as a single comparison.
 *
 * A per-pool baseline can be escaped by moving pools. This is the demonstration that it can't be:
 * one address with a confirmed sandwich exit in pool A, and one that has never done anything,
 * quoted against pool B — a pool that has never seen either of them. Same pool, same size, same
 * block, two different answers.
 *
 * Both figures are read live, so if the memory has decayed since the attack the gap will have
 * narrowed — which is the honest thing for it to do, and worth showing.
 */

const EXPLORER = unichainSepolia.blockExplorers.default.url;
/**
 * The control address for the comparison.
 *
 * The burn address, chosen because it is the one address guaranteed to have no trading history
 * anywhere. Truncated to the first ten characters it renders as "0x00000000…", which reads as a
 * null placeholder rather than a deliberate choice, so the label shows both ends and says why.
 */
const STRANGER = "0x000000000000000000000000000000000000dEaD" as const;
const PROBE = 0.1;

type Props = {
  hook: `0x${string}`;
  poolB: `0x${string}`;
  attacker: `0x${string}`;
  attackBlock: number;
  window: number;
  baseFee: number;
};

export function Immunity({ hook, poolB, attacker, attackBlock, window: immWindow, baseFee }: Props) {
  const [fees, setFees] = useState<{ attacker: number; stranger: number } | null>(null);
  const [signal, setSignal] = useState<number>(0);

  useEffect(() => {
    let stop = false;
    Promise.all([
      quoteSwap(hook, poolB, attacker, true, PROBE),
      quoteSwap(hook, poolB, STRANGER, true, PROBE),
    ])
      .then(([a, s]) => {
        if (stop) return;
        setFees({ attacker: a.totalFee, stranger: s.totalFee });
        setSignal(a.signal);
      })
      .catch(() => undefined);
    return () => {
      stop = true;
    };
  }, [hook, poolB, attacker]);

  const a = fees?.attacker ?? baseFee;
  const s = fees?.stranger ?? baseFee;
  const ratio = s > 0 ? a / s : 1;
  const faded = fees != null && a <= s;

  return (
    <div className="imm">
      <div className="imm-grid">
        <motion.div className="imm-card" initial={{ opacity: 0, y: 12 }} whileInView={{ opacity: 1, y: 0 }}
                    viewport={{ once: true }} transition={{ duration: 0.4 }}>
          <div className="imm-head">Never attacked anything</div>
          <div className="imm-fee">{(s / 10000).toFixed(2)}%</div>
          <code className="imm-addr" title={STRANGER}>
            0x0000…dEaD <em>the burn address, chosen because it has no history</em>
          </code>
          <p>Pool B has no record of this address, so it pays the ordinary fee.</p>
        </motion.div>

        <motion.div className={`imm-card ${faded ? "" : "is-marked"}`} initial={{ opacity: 0, y: 12 }}
                    whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }}
                    transition={{ duration: 0.4, delay: 0.12 }}>
          <div className="imm-head">Sandwiched pool A</div>
          <div className="imm-fee">{(a / 10000).toFixed(2)}%</div>
          <code className="imm-addr">{attacker.slice(0, 10)}…</code>
          <p>
            Pool B has never seen this address either. It prices them anyway, because the record is
            held against the trader, not the pool.
          </p>
        </motion.div>
      </div>

      <div className={`imm-verdict ${faded ? "is-faded" : ""}`}>
        {faded ? (
          <>
            <strong>The memory has decayed.</strong> More than {immWindow.toLocaleString()} blocks have
            passed since the confirmed exit in{" "}
            <a href={`${EXPLORER}/block/${attackBlock}`} target="_blank" rel="noreferrer">
              block {attackBlock}
            </a>
            , so this address is a stranger again. That is the design working, not failing — a mark
            that never fades is a blacklist.
          </>
        ) : (
          <>
            <strong>{ratio.toFixed(1)}× the fee</strong>, in a pool where neither address has ever
            traded, for a swap of identical size. The difference is one confirmed sandwich exit in{" "}
            <a href={`${EXPLORER}/block/${attackBlock}`} target="_blank" rel="noreferrer">
              block {attackBlock}
            </a>{" "}
            — in a <em>different pool</em>. Signal: <code>{signal === 4 ? "CrossPoolMemory" : "None"}</code>.
          </>
        )}
      </div>

      <p className="footnote">
        The surcharge decays linearly to exactly zero over {immWindow.toLocaleString()} blocks
        (~14 hours here). Decay is what keeps this memory rather than a ban: the swap always
        executes, the 5% ceiling always binds, anyone can age out of it by not sandwiching, and no
        owner can extend, clear, or target it. Keyed on <code>tx.origin</code>, so a determined
        attacker rotates addresses — this raises the cost of sandwiching across pools, it does not
        eliminate it.
      </p>
    </div>
  );
}

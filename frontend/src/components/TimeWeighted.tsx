import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import { fetchConstants, type HookConstants } from "../lib/chain";

/**
 * The time-weighted schedule, made visible.
 *
 * A v4 hook cannot pause, queue or reorder a swap — so "time-weighted execution" cannot mean a
 * delay, and claiming otherwise would produce a callback that doesn't do what it says. What it can
 * mean is that temporal clustering costs money: trading the same pool again within a few blocks
 * draws a surcharge that halves every block and reaches exactly zero at the window edge.
 *
 * The schedule below is computed from the contract's own constants, read live. The curve is the
 * arithmetic those constants imply — the on-chain behaviour itself is asserted by a test that
 * measures the surcharge at 0, 1, 2, 4 and 8 blocks' distance and requires it to be exactly zero
 * at the edge rather than merely small.
 */

export function TimeWeighted({ hook }: { hook: `0x${string}` }) {
  const [c, setC] = useState<HookConstants | null>(null);
  const [hover, setHover] = useState<number | null>(null);

  useEffect(() => {
    let stop = false;
    fetchConstants(hook)
      .then((v) => !stop && setC(v))
      .catch(() => undefined);
    return () => {
      stop = true;
    };
  }, [hook]);

  if (!c) return <p className="footnote">Reading the schedule from the contract…</p>;

  const maxSurcharge = (c.maxTotalFee - c.baseFee) / 2;
  const steps = Array.from({ length: c.decayWindow + 1 }, (_, blocks) => ({
    blocks,
    // Halves per block, hard zero at the window edge — the explicit bound is what makes
    // "zero after N blocks" a testable statement rather than an artifact of integer shifting.
    surcharge: blocks >= c.decayWindow ? 0 : Math.floor(maxSurcharge / 2 ** blocks),
  }));

  const peak = steps[0].surcharge;
  const active = hover ?? 0;
  const shown = steps[active];

  return (
    <div className="tw">
      <div className="tw-bars" role="img" aria-label="Recency surcharge by blocks since the trader's last swap">
        {steps.map((s) => {
          const h = peak > 0 ? (s.surcharge / peak) * 100 : 0;
          return (
            <button
              key={s.blocks}
              className={`tw-bar ${active === s.blocks ? "is-active" : ""} ${s.surcharge === 0 ? "is-zero" : ""}`}
              onMouseEnter={() => setHover(s.blocks)}
              onFocus={() => setHover(s.blocks)}
              onMouseLeave={() => setHover(null)}
              onBlur={() => setHover(null)}
              aria-label={`${s.blocks} blocks: ${(s.surcharge / 10000).toFixed(2)}% surcharge`}
            >
              <motion.span
                className="tw-fill"
                initial={{ height: 0 }}
                whileInView={{ height: `${Math.max(h, 1.5)}%` }}
                viewport={{ once: true }}
                transition={{ duration: 0.5, delay: s.blocks * 0.05, ease: [0.22, 1, 0.36, 1] }}
              />
              <span className="tw-x">{s.blocks}</span>
            </button>
          );
        })}
      </div>

      <div className="tw-readout">
        <div>
          <span>blocks since this trader last swapped</span>
          <strong>{shown.blocks}</strong>
        </div>
        <div>
          <span>recency surcharge</span>
          <strong>{(shown.surcharge / 10000).toFixed(2)}%</strong>
        </div>
        <div>
          <span>{shown.surcharge === 0 ? "status" : "share of peak"}</span>
          <strong>
            {shown.surcharge === 0 ? "expired" : `${Math.round((shown.surcharge / peak) * 100)}%`}
          </strong>
        </div>
      </div>

      <p className="tw-note">
        A hook cannot delay a swap — the transaction executes or it reverts, and there is no
        scheduler. So the time-weighted response is a price on <em>temporal clustering</em>, which is
        the thing a sandwich structurally requires. Same-block re-entry pays the maximum; after{" "}
        {c.decayWindow} blocks it costs nothing at all.
      </p>
      <p className="footnote">
        Surcharge peaks at {(peak / 10000).toFixed(2)}% and applies on top of a statistical flag
        only, never on its own — trading often is not penalised, trading often <em>while outside the
        pool's band</em> is. Window and ceiling read live from the contract.
      </p>
    </div>
  );
}

import { Link } from "react-router-dom";
import { motion } from "framer-motion";

/**
 * The four UHI10 categories this project claims, each pointing at the thing that backs it.
 *
 * A claimed category with nothing behind it is worse than not claiming it, so the fifth — MEV
 * Auction — is listed as deliberately not attempted rather than quietly omitted. Three real
 * categories beat five padded ones, and saying so plainly is cheaper than being caught.
 */

const ROWS: Array<{ name: string; how: string; to: string; label: string; claimed: boolean }> = [
  {
    name: "Sandwich-Neutralizing",
    how: "Structural detection at the attacker's exit, priced at the ceiling and paid to LPs.",
    to: "/attack",
    label: "See a caught sandwich",
    claimed: true,
  },
  {
    name: "Time-Weighted Execution",
    how: "A surcharge on temporal clustering that halves per block and expires exactly at the window edge.",
    to: "/how",
    label: "See the decay schedule",
    claimed: true,
  },
  {
    name: "Fee-Rebate Systems",
    how: "The penalty rides Uniswap's native dynamic-fee override, so it accrues to liquidity providers. The hook never holds funds.",
    to: "/attack",
    label: "See where the fee went",
    claimed: true,
  },
  {
    name: "Hybrid Routing",
    how: "A typed signal any router can consume. Interface and events only — no router integration is claimed.",
    to: "/how",
    label: "See the interface",
    claimed: true,
  },
  {
    name: "MEV Auction",
    how: "Deliberately not attempted. A bidding and settlement subsystem is a different, much larger project, and padding a category is worse than leaving it empty.",
    to: "",
    label: "",
    claimed: false,
  },
];

export function Categories() {
  return (
    <ul className="cats">
      {ROWS.map((r, i) => (
        <motion.li
          key={r.name}
          className={r.claimed ? "" : "is-skipped"}
          initial={{ opacity: 0, x: -8 }}
          whileInView={{ opacity: 1, x: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.35, delay: i * 0.07 }}
        >
          <span className="cat-mark" aria-hidden="true">{r.claimed ? "✓" : "—"}</span>
          <div className="cat-body">
            <strong>{r.name}</strong>
            <p>{r.how}</p>
          </div>
          {r.claimed && (
            <Link className="cat-link" to={r.to}>
              {r.label} →
            </Link>
          )}
        </motion.li>
      ))}
    </ul>
  );
}

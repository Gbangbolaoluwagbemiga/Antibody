import { NavLink, Outlet } from "react-router-dom";
import seed from "../data/history.json";
import type { History } from "../lib/types";
import { unichainSepolia } from "../lib/chain";
import { LiveStatus } from "./LiveStatus";

const H = seed as unknown as History;
const EXPLORER = unichainSepolia.blockExplorers.default.url;
const short = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;

const PAGES = [
  { to: "/", label: "Overview", end: true },
  { to: "/try", label: "Try it" },
  { to: "/attack", label: "The attack" },
  { to: "/how", label: "How it works" },
  { to: "/verify", label: "Verify" },
];

export function Shell() {
  return (
    <div className="shell">
      <header className="masthead">
        <div>
          <div className="brand">
            <svg className="mark" viewBox="0 0 32 32" aria-hidden="true">
              <path d="M16 3 5 9v9c0 6.2 4.6 10.4 11 12 6.4-1.6 11-5.8 11-12V9L16 3Z" fill="none"
                    stroke="var(--accent)" strokeWidth="2" strokeLinejoin="round" />
              <path d="M11 16.5 14.5 20l7-7.5" fill="none" stroke="var(--accent)" strokeWidth="2"
                    strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            <h1>Antibody</h1>
          </div>
          <p className="tagline">
            A Uniswap v4 hook that makes MEV extraction unprofitable by pricing it — against a
            threshold each pool computes for itself, from its own trading history.
          </p>
        </div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "flex-start" }}>
          <LiveStatus />
          <a className="chip" href={`${EXPLORER}/address/${H.hook}`} target="_blank" rel="noreferrer">
            hook {short(H.hook)} ↗
          </a>
        </div>
      </header>

      <nav className="nav" aria-label="Sections">
        {PAGES.map((p) => (
          <NavLink key={p.to} to={p.to} end={p.end}
                   className={({ isActive }) => (isActive ? "active" : undefined)}>
            {p.label}
          </NavLink>
        ))}
      </nav>

      <Outlet />
    </div>
  );
}

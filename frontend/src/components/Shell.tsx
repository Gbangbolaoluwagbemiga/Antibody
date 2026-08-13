import { useState } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { motion, useReducedMotion } from "framer-motion";
import seed from "../data/history.json";
import type { History } from "../lib/types";
import { unichainSepolia } from "../lib/chain";
import { LiveStatus } from "./LiveStatus";
import { ThemeToggle } from "./ThemeToggle";

const H = seed as unknown as History;
const EXPLORER = unichainSepolia.blockExplorers.default.url;
const short = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;

const PAGES = [
  { to: "/", label: "Overview", hint: "two pools, one hook", end: true },
  { to: "/try", label: "Try it", hint: "price and swap, live" },
  { to: "/attack", label: "The attack", hint: "fire one yourself" },
  { to: "/how", label: "How it works", hint: "mechanism and cost" },
  { to: "/verify", label: "Verify", hint: "addresses and limits" },
];

export function Shell() {
  const [open, setOpen] = useState(false);
  const { pathname } = useLocation();
  const reduce = useReducedMotion();

  return (
    <div className="layout">
      <button className="sidebar-toggle" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span aria-hidden="true">☰</span> Menu
      </button>

      <aside className={`sidebar ${open ? "is-open" : ""}`}>
        <div className="sidebar-brand">
          <svg className="mark" viewBox="0 0 32 32" aria-hidden="true">
            <path d="M16 3 5 9v9c0 6.2 4.6 10.4 11 12 6.4-1.6 11-5.8 11-12V9L16 3Z" fill="none"
                  stroke="var(--accent)" strokeWidth="2" strokeLinejoin="round" />
            <path d="M11 16.5 14.5 20l7-7.5" fill="none" stroke="var(--accent)" strokeWidth="2"
                  strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          <div>
            <strong>Antibody</strong>
            <span>Uniswap v4 hook</span>
          </div>
        </div>

        <nav className="sidebar-nav" aria-label="Sections">
          {PAGES.map((p) => (
            <NavLink key={p.to} to={p.to} end={p.end} onClick={() => setOpen(false)}
                     className={({ isActive }) => (isActive ? "active" : undefined)}>
              <span className="sn-label">{p.label}</span>
              <span className="sn-hint">{p.hint}</span>
            </NavLink>
          ))}
        </nav>

        <div className="sidebar-foot">
          <LiveStatus />
          <a className="chip" href={`${EXPLORER}/address/${H.hook}`} target="_blank" rel="noreferrer">
            {short(H.hook)} ↗
          </a>
          <a className="chip" href="https://github.com/Gbangbolaoluwagbemiga/Antibody" target="_blank" rel="noreferrer">
            source ↗
          </a>
          <ThemeToggle />
        </div>
      </aside>

      {open && <div className="scrim" onClick={() => setOpen(false)} aria-hidden="true" />}

      {/* Keyed on the route so each page animates in on navigation. Short and small on purpose:
          a page that slides a long way on every click stops feeling responsive. */}
      <motion.main
        className="content"
        key={pathname}
        initial={reduce ? false : { opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.26, ease: [0.22, 1, 0.36, 1] }}
      >
        <p className="tagline">
          A Uniswap v4 hook that makes MEV extraction unprofitable by pricing it — against a
          threshold each pool computes for itself, from its own trading history.
        </p>
        <Outlet />
      </motion.main>
    </div>
  );
}

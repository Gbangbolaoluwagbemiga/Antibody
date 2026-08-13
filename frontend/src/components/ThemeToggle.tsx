import { useEffect, useState } from "react";

/**
 * Three states, not two: light, dark, and system.
 *
 * "System" has to be a real, selectable option rather than merely the default — a viewer whose OS
 * switches at sunset should be able to keep following it after they have poked the toggle. The
 * stylesheet is built for exactly this: the light palette lives on bare `:root`, the dark palette
 * is declared under both `prefers-color-scheme` and `[data-theme="dark"]`, and clearing the
 * attribute hands control back to the OS.
 */

type Mode = "system" | "light" | "dark";
const KEY = "antibody-theme";

function apply(mode: Mode) {
  const root = document.documentElement;
  if (mode === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", mode);
}

const OPTIONS: Array<{ mode: Mode; label: string; icon: string }> = [
  { mode: "light", label: "Light", icon: "☀" },
  { mode: "dark", label: "Dark", icon: "☾" },
  { mode: "system", label: "System", icon: "◐" },
];

export function ThemeToggle() {
  const [mode, setMode] = useState<Mode>(() => (localStorage.getItem(KEY) as Mode) || "system");

  useEffect(() => {
    apply(mode);
    if (mode === "system") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, mode);
  }, [mode]);

  return (
    <div className="theme-toggle" role="group" aria-label="Colour theme">
      {OPTIONS.map((o) => (
        <button
          key={o.mode}
          onClick={() => setMode(o.mode)}
          aria-pressed={mode === o.mode}
          title={o.label}
        >
          <span aria-hidden="true">{o.icon}</span>
          <span className="sr-only">{o.label}</span>
        </button>
      ))}
    </div>
  );
}

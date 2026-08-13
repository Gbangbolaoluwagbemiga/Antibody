import { useEffect, useState } from "react";
import { client } from "../lib/chain";

/**
 * Proves the page is actually talking to a chain, by showing the head block advancing.
 *
 * A static "live" badge is worth nothing — the previous version displayed one while its data
 * fetch had been broken for hours. A block number that visibly ticks cannot fake it.
 */
export function LiveStatus() {
  const [head, setHead] = useState<bigint | null>(null);
  const [ok, setOk] = useState(true);

  useEffect(() => {
    let stop = false;
    const tick = () =>
      client
        .getBlockNumber()
        .then((b) => !stop && (setHead(b), setOk(true)))
        .catch(() => !stop && setOk(false));
    tick();
    const id = setInterval(tick, 4000);
    return () => {
      stop = true;
      clearInterval(id);
    };
  }, []);

  return (
    <span className="chip" title="Unichain Sepolia head block">
      <span className="dot" style={{ background: ok ? "var(--series-mean)" : "var(--status-flagged)" }} />
      {ok && head ? `block ${head.toString()}` : "chain unreachable"}
    </span>
  );
}

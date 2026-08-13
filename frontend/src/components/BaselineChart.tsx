import { useMemo, useRef, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
import type { Point } from "../lib/types";

/**
 * The chart the whole submission rests on: a pool's detection threshold, over the pool's own
 * trading history.
 *
 * The story is in three acts and the geometry is built to make them unmissable:
 *   1. The threshold line does not exist for the first 19 swaps. Not zero, not flat — absent.
 *      Below `minSamples` the hook publishes no opinion, and drawing one would misrepresent that.
 *   2. It appears at n=20 and *narrows* as consistent flow confirms what normal looks like.
 *   3. It climbs sharply where the attack lands, and the flagged swaps sit above the band.
 *
 * Every value plotted is read from `BaselineUpdated` logs emitted by the deployed hook on Unichain
 * Sepolia. Nothing here is synthetic.
 */

const W = 900;
const H = 380;
const M = { top: 22, right: 116, bottom: 46, left: 58 };
const PW = W - M.left - M.right;
const PH = H - M.top - M.bottom;

type Props = { points: Point[]; minSamples: number };

export function BaselineChart({ points, minSamples }: Props) {
  const reduce = useReducedMotion();
  const svgRef = useRef<SVGSVGElement>(null);
  const [hover, setHover] = useState<Point | null>(null);
  const [pos, setPos] = useState({ x: 0, y: 0 });

  const { xs, ys, yMax, calibrated, flagged } = useMemo(() => {
    const yTop = Math.max(...points.map((p) => Math.max(p.threshold, p.mean, p.observed ?? 0))) * 1.12;
    const nMin = points[0].n;
    const nMax = points[points.length - 1].n;
    return {
      xs: (n: number) => M.left + ((n - nMin) / (nMax - nMin)) * PW,
      ys: (v: number) => M.top + PH - (v / yTop) * PH,
      yMax: yTop,
      calibrated: points.filter((p) => p.threshold > 0),
      flagged: points.filter((p) => p.signal),
    };
  }, [points]);

  const linePath = (pts: Point[], key: "mean" | "threshold") =>
    pts.map((p, i) => `${i === 0 ? "M" : "L"}${xs(p.n).toFixed(1)},${ys(p[key]).toFixed(1)}`).join(" ");

  // The "normal range" band: everything under the threshold, once a threshold exists.
  const bandPath = calibrated.length
    ? `M${xs(calibrated[0].n)},${ys(0)} ` +
      calibrated.map((p) => `L${xs(p.n).toFixed(1)},${ys(p.threshold).toFixed(1)}`).join(" ") +
      ` L${xs(calibrated[calibrated.length - 1].n)},${ys(0)} Z`
    : "";

  const yTicks = Array.from({ length: 5 }, (_, i) => (yMax / 4) * i);
  const xTicks = points.filter((p) => p.n % 5 === 0 || p.n === points[0].n);

  function onMove(e: React.PointerEvent<SVGSVGElement>) {
    const rect = svgRef.current!.getBoundingClientRect();
    const px = ((e.clientX - rect.left) / rect.width) * W;
    let best = points[0];
    for (const p of points) if (Math.abs(xs(p.n) - px) < Math.abs(xs(best.n) - px)) best = p;
    setHover(best);
    setPos({ x: (xs(best.n) / W) * rect.width, y: (ys(best.threshold || best.mean) / H) * rect.height });
  }

  const gateX = xs(minSamples);

  return (
    <div className="chart-wrap">
      <ul className="legend">
        <li>
          <span className="swatch line" style={{ background: "var(--series-threshold)" }} />
          Detection threshold (μ + 3δ)
        </li>
        <li>
          <span className="swatch line" style={{ background: "var(--series-mean)" }} />
          Mean trade size (μ)
        </li>
        <li>
          <span className="swatch ring" style={{ background: "var(--status-flagged)", width: 10, height: 10 }} />
          Flagged swap
        </li>
      </ul>

      <svg
        ref={svgRef}
        className="chart"
        viewBox={`0 0 ${W} ${H}`}
        role="img"
        aria-label="Detection threshold and mean trade size over the pool's observed swap history, from live Unichain Sepolia data"
        onPointerMove={onMove}
        onPointerLeave={() => setHover(null)}
      >
        {yTicks.map((t, i) => (
          <g key={i}>
            <line className="grid-line" x1={M.left} x2={M.left + PW} y1={ys(t)} y2={ys(t)} />
            <text className="axis-text" x={M.left - 9} y={ys(t) + 3.5} textAnchor="end">
              {t.toFixed(2)}%
            </text>
          </g>
        ))}

        {/* The calibration gate. Left of this line the hook has no opinion at all. */}
        <line className="rule" x1={gateX} x2={gateX} y1={M.top} y2={M.top + PH} />
        <text className="zone-label" x={gateX - 8} y={M.top + 12} textAnchor="end">
          no opinion yet
        </text>
        <text className="zone-label" x={gateX + 8} y={M.top + 12}>
          threshold live — {minSamples} swaps observed
        </text>

        <path d={bandPath} fill="var(--series-threshold)" opacity={0.1} />

        {/* The lines draw themselves in, left to right — the same direction the pool accumulated
            the history. Skipped entirely under prefers-reduced-motion. */}
        <motion.path
          d={linePath(points, "mean")} fill="none" stroke="var(--series-mean)" strokeWidth={2}
          strokeLinejoin="round" strokeLinecap="round"
          initial={reduce ? false : { pathLength: 0 }}
          whileInView={{ pathLength: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 1.1, ease: "easeOut" }}
        />
        <motion.path
          d={linePath(calibrated, "threshold")} fill="none" stroke="var(--series-threshold)" strokeWidth={2}
          strokeLinejoin="round" strokeLinecap="round"
          initial={reduce ? false : { pathLength: 0 }}
          whileInView={{ pathLength: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 1.1, delay: 0.25, ease: "easeOut" }}
        />

        {/* Flagged swaps: the observed size, plotted where it actually sat relative to the band.
            Ringed and larger — a distinct mark, so identity never rests on colour alone.
            The stem matters: without it these read as dots floating in empty space. Anchoring each
            one to the threshold it breached is the whole point — the gap IS the violation. */}
        {flagged.map((p) => (
          <g key={p.n}>
            <line
              x1={xs(p.n)} x2={xs(p.n)}
              y1={ys(p.threshold > 0 ? p.threshold : p.mean)} y2={ys(p.observed ?? p.mean)}
              stroke="var(--status-flagged)" strokeWidth={1.5} opacity={0.45}
            />
            <motion.circle cx={xs(p.n)} cy={ys(p.observed ?? p.mean)} r={6.5}
                    fill="var(--status-flagged)" stroke="var(--surface-1)" strokeWidth={2}
                    initial={reduce ? false : { scale: 0, opacity: 0 }}
                    whileInView={{ scale: 1, opacity: 1 }}
                    viewport={{ once: true }}
                    style={{ transformBox: "fill-box", transformOrigin: "center" }}
                    transition={{ delay: 1.15, type: "spring", stiffness: 400, damping: 18 }} />
          </g>
        ))}

        {/* Direct labels — required, since the red/aqua pair sits in the colourblind warn band. */}
        <text className="series-label" x={M.left + PW + 10} y={ys(points[points.length - 1].threshold) + 4}
              fill="var(--series-threshold)">
          threshold
        </text>
        <text className="series-label" x={M.left + PW + 10} y={ys(points[points.length - 1].mean) + 4}
              fill="var(--series-mean)">
          mean
        </text>

        {/* Magnified calibration window.
            On the main axis the attack pushes the ceiling to ~2%, which flattens the threshold's
            0.168% -> 0.143% narrowing into a straight line — and that narrowing is the clearest
            evidence the baseline is learning rather than sitting still. It gets its own scale,
            drawn in the space the main series leaves empty. */}
        {calibrated.length > 2 && (() => {
          const win = calibrated.filter((p) => p.n <= calibrated[0].n + 6);
          if (win.length < 3) return null;
          const bx = M.left + 26, by = M.top + 40, bw = 224, bh = 84;
          const lo = Math.min(...win.map((p) => p.threshold));
          const hi = Math.max(...win.map((p) => p.threshold));
          const ix = (n: number) => bx + ((n - win[0].n) / (win[win.length - 1].n - win[0].n)) * bw;
          const iy = (v: number) => by + bh - ((v - lo) / (hi - lo || 1)) * bh;
          return (
            <g>
              <rect x={bx - 16} y={by - 30} width={bw + 78} height={bh + 58} rx={7}
                    fill="var(--surface-2)" stroke="var(--border)" opacity={0.96} />
              <text className="zone-label" x={bx - 8} y={by - 15}>
                calibration window, magnified
              </text>
              <path
                d={win.map((p, i) => `${i ? "L" : "M"}${ix(p.n).toFixed(1)},${iy(p.threshold).toFixed(1)}`).join(" ")}
                fill="none" stroke="var(--series-threshold)" strokeWidth={2}
                strokeLinecap="round" strokeLinejoin="round"
              />
              <circle cx={ix(win[0].n)} cy={iy(win[0].threshold)} r={3.5} fill="var(--series-threshold)" />
              <circle cx={ix(win[win.length - 1].n)} cy={iy(win[win.length - 1].threshold)} r={3.5}
                      fill="var(--series-threshold)" />
              {/* Endpoint values as one caption rather than two inline labels. Inline labels
                  collided with the descending line at their right edge — the line falls ~84px
                  across the inset, so any text placed beside a point gets crossed by it. */}
              <text className="zone-label" x={bx - 8} y={by + bh + 19}>
                <tspan fill="var(--series-threshold)" fontWeight={600}>
                  {win[0].threshold.toFixed(3)}% → {win[win.length - 1].threshold.toFixed(3)}%
                </tspan>
                <tspan> — narrows as the pool grows confident</tspan>
              </text>
            </g>
          );
        })()}

        {hover && (
          <>
            <line className="crosshair" x1={xs(hover.n)} x2={xs(hover.n)} y1={M.top} y2={M.top + PH} />
            <circle cx={xs(hover.n)} cy={ys(hover.mean)} r={4} fill="var(--series-mean)" />
            {hover.threshold > 0 && (
              <circle cx={xs(hover.n)} cy={ys(hover.threshold)} r={4} fill="var(--series-threshold)" />
            )}
          </>
        )}

        {xTicks.map((p) => (
          <text key={p.n} className="axis-text" x={xs(p.n)} y={M.top + PH + 18} textAnchor="middle">
            {p.n}
          </text>
        ))}
        <text className="axis-title" x={M.left + PW / 2} y={H - 8} textAnchor="middle">
          swaps observed by this pool
        </text>
        <text className="axis-title" transform={`rotate(-90) translate(${-(M.top + PH / 2)} 14)`} textAnchor="middle">
          trade size as % of pool liquidity
        </text>
      </svg>

      {hover && (
        <div
          className="tooltip"
          style={{
            left: Math.min(pos.x + 14, 700),
            top: Math.max(pos.y - 20, 0),
          }}
        >
          <div className="tt-head">swap #{hover.n} · block {hover.block}</div>
          <div className="tt-row">
            <span>mean</span>
            <span>{hover.mean.toFixed(4)}%</span>
          </div>
          <div className="tt-row">
            <span>threshold</span>
            <span>{hover.threshold > 0 ? `${hover.threshold.toFixed(4)}%` : "not yet earned"}</span>
          </div>
          {hover.observed != null && (
            <div className="tt-row">
              <span>this swap</span>
              <span>{hover.observed.toFixed(4)}%</span>
            </div>
          )}
          {hover.signal && (
            <div className="tt-flag">
              {hover.signal} · +{(hover.penalty / 10000).toFixed(2)}% fee
            </div>
          )}
        </div>
      )}
    </div>
  );
}

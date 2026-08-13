import { motion } from "framer-motion";
import type { Point } from "../lib/types";

/**
 * The claim, made unarguable.
 *
 * A skeptic reading a single pool's threshold can reasonably say "you picked that number." The
 * answer is two pools on the *same deployed hook* — same address, same bytecode, same parameters —
 * that independently arrived at boundaries a factor of three apart, because they saw different
 * flow. Nothing distinguishes them except their own history.
 *
 * This is the direct answer to the criticism that sank the previous attempt: *"difficult to
 * imagine how it would evolve beyond being a rule base engine that rely on subjective inputs."*
 * There is no input here to be subjective about.
 */

type PoolSummary = {
  label: string;
  poolId: string;
  regime: string;
  story: string;
  points: Point[];
  accent: string;
};

function Sparkline({ points, accent, max }: { points: Point[]; accent: string; max: number }) {
  const W = 260;
  const H = 54;
  const live = points.filter((p) => p.threshold > 0);
  if (live.length < 2) return null;

  const x = (i: number) => (i / (live.length - 1)) * W;
  const y = (v: number) => H - (v / max) * H;
  const d = live.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p.threshold).toFixed(1)}`).join(" ");

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="spark" aria-hidden="true" preserveAspectRatio="none">
      <motion.path
        d={d}
        fill="none"
        stroke={accent}
        strokeWidth={2}
        strokeLinecap="round"
        strokeLinejoin="round"
        initial={{ pathLength: 0 }}
        whileInView={{ pathLength: 1 }}
        viewport={{ once: true }}
        transition={{ duration: 0.9, ease: "easeOut" }}
      />
    </svg>
  );
}

export function TwoPools({ pools }: { pools: PoolSummary[] }) {
  const finals = pools.map((p) => p.points[p.points.length - 1]);
  const max = Math.max(...pools.flatMap((p) => p.points.map((q) => q.threshold))) * 1.1;
  const ratio = Math.max(...finals.map((f) => f.threshold)) / Math.min(...finals.map((f) => f.threshold));

  return (
    <>
      <div className="pools">
        {pools.map((pool, i) => {
          const f = pool.points[pool.points.length - 1];
          return (
            <motion.div
              key={pool.poolId}
              className="pool-card"
              initial={{ opacity: 0, y: 16 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.45, delay: i * 0.12 }}
            >
              <div className="pool-head">
                <span className="pool-label" style={{ color: pool.accent }}>
                  {pool.label}
                </span>
                <code className="pool-id">{pool.poolId.slice(0, 10)}…</code>
              </div>

              <div className="pool-threshold" style={{ color: pool.accent }}>
                {f.threshold.toFixed(3)}%
              </div>
              <div className="pool-sub">learned detection boundary</div>

              <Sparkline points={pool.points} accent={pool.accent} max={max} />

              <dl className="pool-stats">
                <div>
                  <dt>flow it saw</dt>
                  <dd>{pool.regime}</dd>
                </div>
                <div>
                  <dt>mean</dt>
                  <dd>{f.mean.toFixed(4)}%</dd>
                </div>
                <div>
                  <dt>deviation</dt>
                  <dd>{f.dev.toFixed(4)}%</dd>
                </div>
                <div>
                  <dt>swaps observed</dt>
                  <dd>{f.n}</dd>
                </div>
              </dl>

              <p className="pool-story">{pool.story}</p>
            </motion.div>
          );
        })}
      </div>

      <div className="pools-verdict">
        <strong>Same hook. Same bytecode. Same parameters.</strong> Two pools that independently
        arrived at boundaries <strong>{ratio.toFixed(1)}× apart</strong>, because they saw different
        flow. Nothing was configured per-pool — there is no per-pool setting to configure. Each
        number is a consequence of that pool's own history and nothing else.
      </div>
    </>
  );
}

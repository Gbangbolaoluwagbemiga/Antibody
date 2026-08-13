import { useEffect } from "react";
import { motion, useSpring, useTransform, useReducedMotion } from "framer-motion";

/** A number that animates to its target instead of snapping. */
export function Ticker({ value, decimals = 2, suffix = "", prefix = "" }: {
  value: number; decimals?: number; suffix?: string; prefix?: string;
}) {
  const reduce = useReducedMotion();
  const spring = useSpring(reduce ? value : 0, { stiffness: 180, damping: 30 });
  const text = useTransform(spring, (v) => `${prefix}${v.toFixed(decimals)}${suffix}`);
  useEffect(() => spring.set(value), [value, spring]);
  return <motion.span>{text}</motion.span>;
}

/**
 * Reveal on scroll. Honours `prefers-reduced-motion` — a judge with vestibular sensitivity should
 * get the content, not the choreography.
 */
export function Reveal({ children, delay = 0, className }: {
  children: React.ReactNode; delay?: number; className?: string;
}) {
  const reduce = useReducedMotion();
  if (reduce) return <div className={className}>{children}</div>;
  return (
    <motion.div
      className={className}
      initial={{ opacity: 0, y: 14 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-60px" }}
      transition={{ duration: 0.45, delay, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  );
}

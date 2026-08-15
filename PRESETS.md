# Preset tiers — design sketch

**Status: designed, not built. Post-hookathon.** Nothing in this document is deployed, and the
contract is frozen for this submission.

Owed from an earlier conversation and never delivered. Writing it down so it is a considered
roadmap item rather than a vague intention.

---

## The problem it solves

Antibody currently ships one set of constants for every pool: `k = 3`, `minSamples = 20`,
`baseFee = 0.30%`, an immunity window of 50,000 blocks. Those are defensible defaults, and they are
wrong for some pools.

A stablecoin pair trades in a tight band where a 3σ boundary is generous — an attacker has a lot of
room before anything fires. A volatile long-tail pair produces genuine 3σ moves constantly, so the
same setting is a false-positive machine. One number cannot serve both, and the honest options are
either to leave it as-is and say so, or to let pool creators choose from a fixed menu.

## Why this does not reopen the honeypot risk

The single most important safety property in Antibody is that **no owner can change what a pool
charges**. The fee ceiling is a constant, not a setting. That is what makes the design trustworthy
in a way an admin-key system is not.

Presets preserve that, on one condition: **the choice is made once, at pool initialisation, and is
immutable thereafter.** A pool creator picks a tier the way they already pick a fee tier and a tick
spacing when creating a Uniswap pool. Nobody — not the hook owner, not the pool creator, not a
compromised key — can change it afterwards.

If presets were owner-adjustable after deployment, every argument this project makes about not
trusting an operator would collapse. They are not.

## The tiers

Three, deliberately. More becomes a configuration surface, which is the thing being avoided.

| | `STABLE` | `STANDARD` | `VOLATILE` |
|---|---|---|---|
| band width `k` | 4 | 3 | 2 |
| `minSamples` | 30 | 20 | 12 |
| base fee | 0.05% | 0.30% | 1.00% |
| immunity window | 50,000 | 50,000 | 50,000 |
| fee ceiling | 5% | 5% | 5% |

The ceiling and the immunity window are **not** per-tier. They are the properties that bound worst
case behaviour, and letting a pool creator widen either would hand back exactly the power the
design refuses to grant.

`k` moves in the counter-intuitive direction on purpose. A stable pair gets a *wider* band in
deviation terms because its deviation is tiny — 4σ of a very small number is still a tight absolute
boundary. A volatile pair gets a narrower multiplier because its deviation is already large.

## How the choice gets made

`PoolManager.initialize` takes no hook data in current v4, so the tier cannot be passed as an
argument. Two workable routes:

**Encode it in the tick spacing.** Ugly, free, and requires no new surface: map a small set of
tick spacings to tiers. Rejected — it overloads a parameter that already means something, and a
pool creator choosing tick spacing for liquidity reasons would get a detection tier by accident.

**A registration call before initialisation.** The creator calls `registerPool(PoolKey, Tier)` on
the hook, which stores the choice keyed by pool id and reverts if that pool already has one.
`_beforeInitialize` reads it, falls back to `STANDARD` if absent, and marks the pool's tier
immutable. This is the one I would build: explicit, single-use, and its failure mode is a pool that
silently gets sensible defaults.

## What it costs

One extra storage slot per pool, read once in `_beforeInitialize` and then on every `_assess` call
to get `k` and `minSamples`. That is one additional SLOAD in the hot path — call it ~2,100 gas cold,
100 warm — on top of the current 37,278 overhead.

Whether that is worth paying for tier flexibility is a real question and I do not think the answer
is obviously yes.

## What would need proving before shipping it

- A test that a registered tier cannot be changed, by anyone, ever, including the hook owner.
- A test that every tier still respects the global fee ceiling, fuzzed across the whole parameter
  space, exactly as the current constants are.
- A test that an unregistered pool gets `STANDARD` rather than reverting or getting zeros.
- Live evidence that `VOLATILE` actually reduces false positives on a genuinely volatile pair,
  rather than assuming it does. The desensitisation and Sybil findings both came from running on a
  real chain, not from reasoning, and there is no reason to expect this to be different.

## Why it is not in this submission

It is a feature, and the last three things that went wrong here were found by running the contract
on a real chain rather than by adding to it. Shipping a fourth mechanism in the final week — after
four redeploys, each of which reset every pool's accumulated state — trades a real risk of new
unknowns for a benefit judges are unlikely to weight heavily.

Three real layers with measured limitations beat four with a thin one.

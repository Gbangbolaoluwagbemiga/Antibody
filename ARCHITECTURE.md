# Antibody — Architecture & Build Plan

**Project ID: `HK-UHI10-1010`** · Solo · `cripticdev` · UHI10 · Sustainable Liquidity & MEV Protection

Companion to [BRIEF.md](BRIEF.md). The brief is the *what and why*; this is the *how*, and it
corrects three points where the brief specifies something Uniswap v4 cannot actually do.

---

## 0. Corrections to the brief

These are settled decisions, not open questions.

**1. There is no "randomized delay to the callback."** A v4 hook cannot pause, queue, or
reschedule a swap — the transaction executes or it reverts, and there is no scheduler. On-chain
randomness (`prevrandao`, blockhash) is visible to the block builder, i.e. to the exact adversary
we are defending against. Building a "delay" here would produce a callback that doesn't do what it
claims — the precise Orbitwork failure mode.

**Replacement:** *time-weighted fee escalation*. The penalty a flagged trader pays scales with how
recently that address last traded this pool — same-block re-entry pays the maximum, halving each
block until it reaches zero. This attacks the sandwich's structural requirement (tight temporal
coupling) with a real, measurable cost, and it honestly earns the Time-Weighted Execution category.

**2. The hook cannot see queued or pending trades.** No mempool visibility, no lookahead into later
transactions in the block. Detection happens at the attacker's **back-run** — the closing leg —
which is the moment the sandwich becomes identifiable on-chain. The victim's fill is already done
at that point; what we destroy is the *profit*, by taxing the exit and paying it to LPs. Sandwiching
stops being +EV. This must be described accurately in pitch copy: **Antibody makes sandwiches
unprofitable, it does not make them impossible.** That claim is defensible and true. The stronger
claim is not.

**3. Transient storage cannot carry state across the sandwich.** `tstore`/`tload` are scoped to a
single transaction; a sandwich is three. Cross-transaction same-block detection therefore requires
real storage with a `block.number` stamp.

This last one is load-bearing in our favour. The write that enables detection *is* the write that
updates the baseline — they are the same SSTORE. The state update cannot be stubbed or deferred to
a lazy view function without the detection mechanism visibly breaking in tests. The Orbitwork flaw
is designed out rather than guarded against.

---

## 1. Mechanism

```
                     ┌─────────────── beforeSwap ───────────────┐
   swap request ───▶ │  read baseline (2 SLOADs)                │
                     │  ├─ Signal A: same-block reversal?       │  confirmed sandwich
                     │  └─ Signal B: size ratio > μ + Kσ ?      │  statistical anomaly
                     │       ↓                                  │
                     │  penalty = f(signal, blocksSinceLastTrade)│
                     │  return fee | OVERRIDE_FEE_FLAG ─────────┼──▶ accrues to LPs
                     └──────────────────────────────────────────┘
                                        ↓ swap executes
                     ┌─────────────── afterSwap ────────────────┐
                     │  realized impact = |tick_after - tick_before|
                     │  EWMA update  ← THE state write          │
                     │  record (sender, block, direction, size) │
                     │  emit BaselineUpdated / ToxicFlowDetected │
                     └──────────────────────────────────────────┘
```

### 1.1 The baseline (objective, self-updating, O(1))

No arrays, no history buffer. Two exponentially-weighted moving averages per pool, updated every
swap, `α = 1/16` implemented as a shift so there is no division:

```
μ  ←  μ + (x − μ) / 16                    // mean of the metric
δ  ←  δ + (|x − μ| − δ) / 16              // mean absolute deviation
threshold  =  μ + K · δ                    // K default 3, owner-settable within hard bounds
```

Mean absolute deviation instead of variance deliberately — no `sqrt` on-chain, same discriminating
power for a threshold.

**Primary metric (gates `beforeSwap`):** `sizeRatio = |amountSpecified| · 1e18 / poolLiquidity`.
Pool-relative, objective, and computable *before* the swap — which is what makes it usable as a
gate. Compared against the pool's own trailing distribution, never a hardcoded number.

**Secondary metric (recorded in `afterSwap`):** realized impact per unit size, from the tick
delta. Drives the routing-signal severity and the UI chart. Tick before the swap is carried
`beforeSwap → afterSwap` in transient storage — a legitimate same-transaction use.

**Cold-start gate:** below `MIN_SAMPLES` (default 20) observed swaps, Signal B is disabled. A
baseline with no data has no opinion, and pretending otherwise would produce exactly the
"subjective inputs" the judges called out. Signal A stays live from swap one — it is structural,
not statistical.

### 1.2 Detection

| Signal | Condition | Confidence | Penalty |
|---|---|---|---|
| **1 — `SandwichExit`** | same trader, same block, opposite direction to its own prior swap, **and a different address traded the pool in between** | High. Structural signature. | Maximum |
| **2 — `BlockReversal`** | pool reversed direction in-block under a *different* address | Medium. Honest same-block arbitrage looks identical. | Half |
| **3 — `SizeAnomaly`** | `sizeRatio > μ + kδ` and `sampleCount ≥ minSamples` | Graduated by distance past the band. | Proportional + recency surcharge |

Detectors run strongest-first, first match wins, so a confirmed sandwich exit is never downgraded.
Signals 1 and 2 are structural and live from the pool's first swap. Signal 3 is the one that gets
*sharper with data* and the one the UI chart visualises.

**Identity — the reason Signal 2 exists.** The `sender` a hook receives is the *router*, not the
person: every user of a shared router collapses into one identity, which would make Signal 1 fire
constantly on unrelated traffic. Antibody keys on `tx.origin`, which is the transaction submitter —
the correct primitive here, since a sandwich requires separately submitted transactions. The known
cost is that account-abstraction bundles and multi-EOA attackers don't resolve to a stable identity.
Signal 2 covers exactly that gap by tracking reversal at the *pool* level, where no identity is
needed at all. This was found while reading the interfaces during scaffolding, not while designing
on paper.

### 1.3 Response

```solidity
penalty = signal1 ? MAX                              // confirmed sandwich exit
        : signal2 ? MAX / 2                          // in-block reversal, different address
        : signal3 ? scaled(ratio - threshold) + recencySurcharge(trader)
        : 0;
return (selector, ZERO_DELTA, min(baseFee + penalty, MAX_TOTAL_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
```

**The time-weighted term is additive, not a decay of the whole penalty.** An earlier draft applied
`penalty >>= blocksSinceLastTrade` to everything, which is wrong: a large toxic trade from a *fresh*
address has a huge `blocksSince` and would have been shifted to zero — the exact case we most want
to catch. Instead the surcharge (`MAX/2`, halving per block, hard zero at `DECAY_WINDOW = 8`) is
added on top of a statistical flag only. Trading often is never penalised on its own; trading often
*while tripping the anomaly band* is.

`MAX_TOTAL_FEE` is 5% and is a **constant, not owner-settable**. A hook that *can* charge 100% is
not a fee mechanism, it's a honeypot — so no key compromise can turn this into a confiscation
device. Fuzzed across the entire reachable parameter space.

The pool is initialised with `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`); `beforeSwap` returns the
override with `OVERRIDE_FEE_FLAG` (`0x400000`). The elevated fee accrues to the pool's fee growth
and is therefore **paid to LPs automatically** — no `donate()` call, no hook-custodied funds, no
`BeforeSwapDelta` accounting, no new attack surface. Attempted extraction converts directly into LP
revenue.

One mechanism, three categories: Sandwich-Neutralizing (A), Time-Weighted Execution (the decay),
Fee-Rebate (the accrual). Worst case for a false positive is an honest trader overpaying fees on one
swap — never a failed transaction. Not griefable into a denial of service.

### 1.4 Routing signal (small, keep it small)

```solidity
event ToxicFlowDetected(PoolId indexed poolId, address indexed trader,
                        uint8 signal, uint256 observedScore, uint256 threshold, uint24 penaltyBps);
event BaselineUpdated(PoolId indexed poolId, uint64 ewmaSizeRatio, uint64 ewmaImpact,
                      uint256 threshold, uint32 sampleCount);
```

Plus a documented `IAntibodySignal` interface so an external router *could* consume it. That is the
entire deliverable for this category. No CoW integration, no Flashbots integration.

`BaselineUpdated` is also the UI's data source — the literal, on-chain, timestamped proof that the
system evolves.

---

## 2. Storage layout

Two slots per pool, one slot per (pool, trader).

```solidity
struct Baseline {                    // 1 slot
    uint64 ewmaSizeRatio;            // μ, primary metric
    uint64 ewmaDeviation;            // δ
    uint64 ewmaImpact;               // secondary metric, realized
    uint32 sampleCount;              // cold-start gate
    uint32 lastBlock;
}

struct TraderRecord {                // 1 slot — powers Signal A *and* the time-weighted decay
    uint32  lastBlock;
    bool    lastZeroForOne;
    uint216 lastAmount;
}

mapping(PoolId => Baseline)                      baselines;
mapping(PoolId => mapping(address => TraderRecord)) traders;
```

`TraderRecord` doing double duty is why the state write is unavoidable rather than dutiful.

---

## 3. Access control (Orbitwork lesson #2)

- All four callbacks: `onlyPoolManager`, enforced, **with a test that calls each one directly from
  an unauthorized EOA and asserts the revert.** Inherited modifiers count as untested until a test
  proves it.
- `setK`, `setMinSamples`, `setMaxPenalty`: `onlyOwner` **and** hard-bounded in the setter, so even
  a compromised owner cannot set a confiscatory fee. Tested from a non-owner and with out-of-range
  values.
- Zero hardcoded addresses. PoolManager, tokens, deployer all from `.env` / deploy config from the
  first commit.

---

## 4. Test matrix

Every row is written **before** the code it covers. Every row maps to a specific claim in the pitch
or a specific Orbitwork mistake.

**Status: 61 passing, 0 failing.** Written before the code they cover, per the discipline section.

| # | Test | Proves | Orbitwork mistake | ✔ |
|---|---|---|---|---|
| 1 | `afterSwap` write read back after a real swap, asserted non-zero | The baseline actually updates | #3, #4 | ✅ |
| 2 | Threshold absent → emerges at `minSamples` → rises with a larger-trade regime | "It gets sharper with data" | #8 | ✅ |
| 3 | Scripted sandwich → back-run classified `SandwichExit` at ceiling | Structural detection works | #1 | ✅ |
| 3b | Legs split across two EOAs → `BlockReversal`, non-zero but below ceiling | Multi-EOA attacker still seen | — | ✅ |
| 4 | Same-size flagged vs. unflagged swap → LP fee growth >5x | The rebate reaches LPs | #1 | ✅ |
| 5 | Surcharge strictly decreases per block, exactly zero at `DECAY_WINDOW` | Time-weighting is a real schedule | #1 | ✅ |
| 5b | Fresh address, anomalous size → still penalised | The decay doesn't exempt the worst case | — | ✅ |
| 6 | Ordinary flow through a calibrated pool → exactly `baseFee`, `Signal.None` | No false positives on honest flow | — | ✅ |
| 6b | Flagged swap still executes | Benign failure mode; not griefable into DoS | — | ✅ |
| 7 | Cold pool → statistical detector silent; structural detector still fires | No cold-start guessing | #8 | ✅ |
| 8 | Every callback called directly by an EOA → reverts; baseline unpoisonable | Access control enforced, not assumed | #2 | ✅ |
| 9 | `setParameters` from non-owner → reverts; out-of-bounds → reverts | Params can't be abused | #2 | ✅ |
| 10 | Fuzzed EWMA, size ratio, tick distance, whole parameter space | Safe under adversarial input | — | ✅ |
| 11 | Gas measured against an identical hookless pool | Honest about the cost imposed | — | ✅ |

### Measured cost

| | Gas |
|---|---|
| Hookless swap, same pool shape | 44,061 |
| Antibody swap | 78,729 |
| **Overhead** | **34,668** |

Three SSTOREs per swap — baseline, trader record, pool record — is the floor for cross-transaction
detection, since transient storage cannot span a sandwich's three transactions. This is a real,
permanent cost paid by every swapper, and the submission should quote it rather than let a judge
find it. The test asserts a 120,000 ceiling so a regression can't quietly erode the tradeoff.

### Bugs caught before they shipped

- **EWMA dead zone.** Any gap under 16 truncated to a zero step, so after a regime shift the
  baseline stalled short of the truth *permanently* — a static rule set reintroduced through a
  fixed-point rounding bug, in the very math meant to prevent one. Fixed by flooring the step at 1.
- **`sizeRatio` reverted on extreme inputs.** `FullMath.mulDiv` overflowed before the saturation
  clamp could run, which would have broken the benign-failure guarantee the whole pitch rests on —
  a swap failing outright rather than overpaying. Now clamps before multiplying.

Both were found by tests, not by reading the code.

### Three more the tests did NOT catch — the chain did

Documented in full in [DEPLOYMENT.md](DEPLOYMENT.md). In short: `SandwichExit` originally lacked
the "a third party traded in between" clause and flagged 23 of 23 ordinary calibration swaps at
maximum penalty; the emitted penalty could exceed the chargeable ceiling because the recency
surcharge was added after the cap; and `SizeAnomaly` turned out to price the sandwich *victim* too
when their trade was itself unusually large.

The first is the instructive one. Every calibration helper in the test suite called `vm.roll`
between swaps, so the same-block round-trip case never arose in testing — the suite was proving
something narrower than it appeared to. A test suite is evidence about the cases it constructs,
never about the ones it never builds.

Mistake #5 (zero tests) is covered by the matrix existing. #6 (committed stubs) and #7 (hardcoded
addresses) are commit-time rules, enforced in CI: build must pass, no `TODO`/`revert("unimplemented")`
in `src/`.

---

## 5. Stack & deployment

- **Foundry**, Solidity `0.8.26`, `v4-core` + `v4-periphery` via `forge install`.
- Starting from **`uniswapfoundation/v4-template`**, not from Orbitwork. Orbitwork's contract layout
  (`EscrowHook`/`EscrowCore`/`OrbitworkRatings`) doesn't map onto this design, and the template is
  the current, clean scaffolding with `HookMiner` and the CREATE2 proxy already wired. Orbitwork's
  value here is its CI workflow and `.env.example` pattern, nothing more.
- **Hook flags:** `BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG`. No return-delta flags — we don't touch
  deltas. Salt mined with `HookMiner.find()` against the CREATE2 proxy
  `0x4e59b44847b379578588920cA78FbF26c0B4956C`; flags in `getHookPermissions()` and the miner call
  must match or deployment fails.
- **Deploy target: Unichain Sepolia.** Qualifies for the Unichain prize track automatically.
- **Demo:** deployed hook on Unichain Sepolia, driven by a `forge script` attacker that executes a
  genuine front-run / victim / back-run sequence against it. Real transaction hashes a judge can
  click.

---

## 6. Frontend

Vite + React + TypeScript + wagmi/viem. Dark, technical, its own identity — not Foreman's green,
not SecureFlow's teal.

Four things it must *show*, in priority order:

1. **The adapting baseline.** Live chart of `threshold` over `sampleCount`, fed by `BaselineUpdated`
   logs. This is the single most persuasive object in the submission — it is the visual answer to
   "how does this evolve beyond a rule base engine." Build this first.
2. **A sandwich caught live.** Fire the attacker script, watch the back-run get flagged in real time.
3. **Before/after.** Same trade against a control pool with no hook vs. the Antibody pool:
   attacker profit extracted, versus attacker profit taxed and LP fees increased. Two numbers, side
   by side.
4. Legible to a non-technical judge in 30 seconds.

---

## 7. Schedule

Today is **Aug 13**. PU1 is **Aug 24**, PU2 **Aug 31**, final **Sept 3**.

> Note: BRIEF.md marks "Idea locked: Aug 17 ✅ done" — that date is in the future. Flag for
> correction before it appears in a progress update.

| Window | Deliverable |
|---|---|
| Aug 13–16 | Scaffold from v4-template. Tests 1, 8, 9 written and **failing**. Minimal hook deployed to Unichain Sepolia. |
| Aug 17–20 | EWMA baseline + `afterSwap` write. Tests 1, 2, 7 green. |
| Aug 21–23 | Signals A & B, fee response, decay. Tests 3–6 green. |
| **Aug 24** | **PU1** — deployed hook, passing suite, sandwich caught in a test. Real, not a slide. |
| Aug 25–29 | Frontend: baseline chart first, then live detection, then before/after. |
| Aug 30–31 | **PU2** — working demo end to end. Fuzz + gas tests. |
| Sept 1–2 | README, demo video, pitch copy. Verify every claim maps to a passing test. |
| **Sept 3** | **Final submission** — https://tally.so/r/mVNEAE, Project ID `HK-UHI10-1010`. |

Frontend starts Aug 25 with three days of slack before PU2. If contract work slips, it eats slack,
not the demo.

---

## 8. The standing rule

Every claim in the pitch copy must name a passing test. If a sentence in the README has no test
behind it, either write the test or delete the sentence. That rule, applied without exception, is
the whole difference between this and Orbitwork.

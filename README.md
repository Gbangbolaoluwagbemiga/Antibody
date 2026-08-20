# Antibody

**A Uniswap v4 hook that makes MEV extraction unprofitable by pricing it — against a threshold the
pool computes for itself.**

UHI10 Hookathon · Project `HK-UHI10-1010` · Theme: Sustainable Liquidity & MEV Protection
Deployed on **Unichain Sepolia** · 69 passing tests

---

## Three layers

| | closes the objection |
|---|---|
| **Earned immunity** — each pool computes its own threshold from its own flow | "your threshold is arbitrary" |
| **Shared memory** — a confirmed sandwich follows the trader across every pool, and decays | "I'll just move to another pool" |
| **Inherited protection** — a new pool opens with an established sibling's baseline | "new pools are defenceless" |

The consequence, and the claim worth testing: **Antibody is the first MEV defence that gets stronger
as more pools adopt it.** Every pool that runs it feeds the shared memory; every new pool inherits
from the ones before it.

## The idea

Most MEV defenses are a rule set someone configured: a threshold, a size limit, an allowlist. They
work until the market moves, and they never get better on their own.

Antibody has no configured threshold. Each pool builds its own statistical baseline from its own
trading history — an exponentially-weighted mean of trade-size-to-liquidity plus a mean-absolute-
deviation band — updated on **every swap**, in `afterSwap`, in storage. A trade is judged against
what is normal *for that pool*, and "normal" is a number the pool learned rather than one a human
picked.

When a trade is flagged, it pays an elevated LP fee through Uniswap v4's native dynamic-fee
override. That fee accrues to the pool's liquidity providers. **Attempted extraction becomes LP
revenue.**

## What it actually does — and doesn't

A hook cannot see the mempool, and it cannot pause, queue, or reorder a swap. So:

> **Antibody makes sandwich attacks unprofitable. It does not make them impossible.**

Detection happens at the attacker's *exit* — the closing leg, which is the moment the pattern
becomes visible on-chain. The victim's fill has already happened. What gets destroyed is the
attacker's profit, which is what makes the strategy stop being worth running.

Everything below is measured, not asserted. See [DEPLOYMENT.md](DEPLOYMENT.md) for transaction
hashes and [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## Caught in the wild

A real sandwich, all three legs in **block 59892284** on Unichain Sepolia:

| leg | signal | penalty |
|---|---|---|
| front-run (attacker) | `SizeAnomaly` | +4.11% |
| **victim** | **not flagged** | **0** |
| **exit (attacker)** | **`SandwichExit`** | **+4.70% — 16.7x the base fee** |

The victim pays nothing extra. The mechanism prices the attacker, not the person being attacked.

### What it cost

Decoded from the PoolManager's own `Swap` events, holding every variable fixed except the fee:

| | without Antibody | with Antibody |
|---|---|---|
| fees on the attacker's two legs | 0.012 | **0.188** |
| attacker net | −0.004 | **−0.180** |
| to liquidity providers | 0.012 | **+0.188** |

**15.7× the fee**, and 0.176 that went to LPs instead of staying with the attacker. Without the
penalty this sandwich was roughly break-even; with it, it loses money — which is the entire point.

The victim's trade here was sized inside the calibrated band on purpose, so the raw extraction
available was small. The deterrent is that the cost scales with the *attacker's own leg size*, not
with how much they manage to extract.

## Attack one pool, every pool remembers

A per-pool baseline has an obvious hole: attack pool A, get priced, move to pool B. So a confirmed
`SandwichExit` writes a record against the **trader**, held by the hook rather than by any pool.

Two addresses quoted against **pool B — which has never seen either of them** — for the same swap:

| | signal | fee |
|---|---|---|
| never attacked anything | `None` | **0.30%** |
| sandwiched pool A | `CrossPoolMemory` | **0.80%** |

2.7× the fee, in a pool where neither address has ever traded. The difference is one confirmed
sandwich exit in [block 59892284](https://sepolia.uniscan.xyz/block/59892284) — in a *different pool*.

The surcharge is 0.50% per confirmed exit, compounds to a bound of four, and **decays linearly to
exactly zero over 50,000 blocks** (~14 hours). Decay is not a softening — it is what keeps this
memory rather than a ban. A permanent mark is a blacklist, which is a censorship surface and a
governance target. Fading means the worst case is a temporary surcharge anyone can age out of by not
sandwiching, the swap always executes, the 5% ceiling always binds, and no owner can extend, clear,
or target any of it.

## The baseline teaches itself

| after | swaps seen | mean | deviation | threshold |
|---|---|---|---|---|
| 19 swaps | 19 | 0.0895% | 0.0280% | *none — uncalibrated* |
| 26 swaps | 26 | 0.0895% | **0.0178%** | **0.1429%** |

Sizes are expressed as a fraction of pool liquidity. **Zero of those 26 swaps were flagged.**

Below `minSamples` the hook publishes **no threshold at all** — a baseline with insufficient data
reports no opinion rather than a misleading one. Then it appears, and the band *tightens* as
consistent flow arrives.

## Detection

| signal | condition | confidence | penalty |
|---|---|---|---|
| `SandwichExit` | same trader, same block, opposite direction — **and a third party traded in between** | structural | maximum |
| `BlockReversal` | pool reversed direction in-block under a *different* address | catches multi-EOA attackers; honest arbitrage looks the same | half |
| `SizeAnomaly` | size-to-liquidity outside the pool's own `μ + kδ` band | graduated by distance past the band | proportional + recency surcharge |
| `CrossPoolMemory` | a confirmed sandwich exit in *any* pool this hook serves, still within the decay window | carried, not local | 0.50% per exit, decaying to zero |

Structural signals need no history and work from a pool's first block. The statistical signal is
suppressed until the pool has earned an opinion.

**Time-weighted execution** is the recency surcharge: trading the same pool again within a few
blocks costs more, halving each block, zero after eight. A hook cannot delay a swap — but it can
make the temporal clustering that sandwiching requires progressively expensive.

## Design decisions worth stating

- **The hook never holds funds.** No `BeforeSwapDelta`, no delta flags, no withdrawal path. The
  penalty rides Uniswap's native LP fee, so an entire class of custody bug is designed out rather
  than guarded against.
- **The fee ceiling is a constant, not a setting.** 5%, unreachable by any owner configuration,
  fuzzed across the whole parameter space. A hook that *can* charge 100% is a honeypot.
- **Failure is benign.** A false positive costs one swap an elevated fee. It never reverts a
  transaction, so the hook cannot be griefed into denial of service.
- **The state write cannot be skipped.** Transient storage is scoped to a single transaction, but a
  sandwich spans three — so cross-transaction detection needs real storage. The SSTORE that enables
  detection *is* the one that updates the baseline. They cannot come apart.

## Cost

| | gas |
|---|---|
| hookless swap | 44,061 |
| Antibody swap | 81,339 |
| **overhead** | **37,278** |

Three SSTOREs per swap, paid by honest flow too. Quoted here rather than left to be discovered.

## Routing signal (Hybrid Routing category)

Live on chain — `ToxicFlowDetected` fires on every flagged swap and `BaselineUpdated` on every
swap, both consumable today at the deployed address. The interface is
[`IAntibodySignal`](contracts/src/interfaces/IAntibodySignal.sol): two events plus
`currentThreshold(poolId)`, `isCalibrated(poolId)` and `quote(...)`, which lets a router price a
swap before sending it. External routers
(CoW, Flashbots Protect) can consume these via [`IAntibodySignal`](contracts/src/interfaces/IAntibodySignal.sol)
to route similar flow privately. Antibody publishes the signal and stops there — no router
integration is attempted.

## Layout

```
contracts/
  src/AntibodyHook.sol              the hook
  src/libraries/BaselineMath.sol    EWMA + deviation band, no division, no sqrt
  src/interfaces/IAntibodySignal.sol
  test/                             69 tests
  script/                           deploy, calibrate, attack, inspect
frontend/
  src/components/BaselineChart.tsx  the threshold, as the pool learned it
  src/lib/chain.ts                  reads BaselineUpdated / ToxicFlowDetected from chain
```

```bash
cd contracts && forge test
cd frontend  && pnpm install && pnpm dev
```

## Demo

The page plots the deployed pool's own history, decoded from `BaselineUpdated` and
`ToxicFlowDetected` logs — a bundled snapshot paints instantly, then it refreshes live from
Unichain Sepolia. Three things it shows that copy alone cannot:

- The threshold is **absent** for the first 19 swaps, not flat at zero. The hook has no opinion and
  the chart does not invent one.
- A magnified inset on the calibration window, because on the main axis the attack pushes the
  ceiling to ~1.6% and flattens the `0.168% → 0.143%` narrowing into a straight line. That narrowing
  is the clearest evidence the baseline is learning.
- Each flagged swap drawn as a stem from the threshold it breached up to where it actually landed.
  The gap is the violation.

Colours were validated for colourblind separation and contrast against both surfaces rather than
picked by eye; every series carries a direct label and the same data is available as a table.

## What running it on a real chain caught

Five defects the original test suite had not, all fixed and regression-tested. Three came from
running on a real chain; two came from tests written afterwards to attack the design rather than
confirm it.

### From the chain

The most important:
**an earlier build flagged 23 of 23 ordinary calibration swaps as sandwiches.** `SandwichExit` was
defined as *same trader, same block, opposite direction* — which is also what a rebalancing market
maker or a multi-hop route looks like. A sandwich is defined by its victim, so the rule now requires
that a *different* address traded in between. The tests missed it because every helper advanced a
block between swaps, so the same-block case never arose.

### From attacking it deliberately

Once the design was working, a round of adversarial tests found two more.

**Donor eligibility was Sybil-able, and the donor slot was permanent.** Pool creation is
permissionless and "earned a baseline" meant nothing more than twenty swaps having happened — so
one address could trade against itself, claim a pair's donor slot forever, and author a band wide
enough that the detector never fired in any pool that inherited it. A test confirmed a 50x-typical
trade paying base fee in the victim pool: not a degraded defence, a disabled one. Qualifying now
costs breadth, time and history, and the slot is displaceable by a pool serving more of the market.

**A bystander was being convicted as a victim.** `SandwichExit` required a third party between the
two legs but ignored which way that trade ran, so a round trip closed across an *opposite*-direction
trade was recorded as a sandwich — when the trader had lost to that trade rather than extracted from
it. The intervening trade must now run the same direction as the entry.

Full account, including the two negative results kept deliberately and the residual risk that
remains after the Sybil fix, in [DEPLOYMENT.md](DEPLOYMENT.md).

## Known limitations

- The statistical detector can be **desensitised** by an attacker who repeatedly trades large sizes,
  dragging the band wider. It does not defeat sandwich detection — the structural signals consult no
  baseline.
- **`SizeAnomaly` does not distinguish attacker from victim.** A sandwich victim making an unusually
  large trade pays the anomaly fee too. Only the structural detectors tell the two apart.
- **Cross-pool memory is keyed on `tx.origin`**, so a determined attacker rotates addresses. It
  raises the cost of sandwiching across pools; it does not eliminate it.
- Identity is `tx.origin`, a heuristic grouping key and never an authorization check. Account-
  abstraction bundles don't resolve to a stable identity; `BlockReversal` covers that gap at the
  pool level.
- **Donor eligibility raises the cost of Sybil, it does not remove it.** An attacker willing to fund
  `MIN_DONOR_TRADERS` addresses and wait `MIN_DONOR_AGE` blocks still qualifies. What they cannot do
  is hold the slot — a pool serving more distinct traders displaces them. There is a test asserting
  exactly this rather than claiming the attack is impossible.
- **A round trip through one pool across same-direction flow is priced as extraction**, whatever the
  trader intended. The middle trade pushed price the way their entry did and they closed against it;
  intent is not observable on chain. Cross-pool arbitrage is unaffected — each pool sees one leg in
  one direction, so nothing fires.
- **A genuinely new token pair has no donor**, so its first pool serves the full cold-start window
  undefended. Inheritance only helps pairs an established pool has already characterised.

## License

MIT

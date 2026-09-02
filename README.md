# Antibody

**Pools that work out their own MEV threshold — and pass it on to the next pool.**

A Uniswap v4 hook. Nothing is configured: each pool derives its detection boundary from its own
trading history, a new pool opens already protected by inheriting an established sibling's, and a
confirmed sandwicher is priced in every pool the hook serves.

It also ships **[MEVBench](contracts/test/bench/MEVBench.sol)** — a harness that measures *any* v4
hook's precision and recall against real Ethereum blocks. MEV hooks report "it caught N attacks" and
almost never report how often they fire on ordinary trading. Running Antibody through it found the
detector I had shipped six times was wrong more than three times out of four. That is on this page, with
the fix.

UHI10 Hookathon · Project `HK-UHI10-1010` · Theme: Sustainable Liquidity & MEV Protection
Deployed and **source-verified** on **Unichain Sepolia** · 83 passing tests

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

## MEVBench — the number nobody publishes

Every MEV hook I could find reports **recall**: "it caught N attacks." Recall alone is worth nothing,
because a detector that fires on every swap also catches 100% of attacks. The number that decides
whether a fee-based defence is usable is **precision**: how often does it fire on ordinary trading?

Antibody's `BlockReversal` shipped across six deployments reporting 25-of-25 on real mainnet
sandwiches. Measured against ordinary blocks for the first time, it fired on **133 of 322** — 41%. The
recall number was true the whole time and hid a broken detector.

So the harness is separated from the hook it was written for:

```bash
python3 research/build_fixture.py --span 600 --pool 0x88e6...5640   # real blocks, ground truth
forge test --match-path test/AntibodyPrecision.t.sol -vv            # confusion matrix
```

`MEVBench` is hook-agnostic — inherit it, implement three functions (`_benchSwap`, `_benchFlagged`,
`_benchActorCount`), and it replays real Ethereum blocks against your detector and reports recall,
precision and false-positive rate. Antibody is simply its first caller; a benchmark only its author
can run is not a benchmark.

Ground truth is the mechanical shape of a sandwich, stated in the fixture so it can be argued with
rather than trusted. Profit is deliberately not modelled — see [the limits](#known-limitations).

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

Read from pool A on the deployed hook:

| after | mean | deviation | threshold |
|---|---|---|---|
| 19 swaps | 0.0895% | 0.0280% | *none — uncalibrated* |
| 20 swaps | 0.0895% | 0.0262% | **0.1682%** — first opinion |
| 63 swaps | 0.1957% | 0.1079% | **0.5193%** — after a large probe |
| 65 swaps | 0.2891% | 0.2010% | **0.8922%** — current |

Sizes are a fraction of pool liquidity. Across **96 ordinary swaps** on both live pools, the hook has returned **0** sandwich verdicts; the 3 attack legs it did flag are the staged attack.

Below `minSamples` the hook publishes **no threshold at all** — a baseline with insufficient data
reports no opinion rather than a misleading one. Then it appears, and the band *tightens* as
consistent flow arrives.

## Detection

| signal | condition | confidence | penalty |
|---|---|---|---|
| `SandwichExit` | same trader, same block, opposite direction — **and a third party traded in between** | structural | maximum |
| `BlockReversal` | pool reversed direction in-block under a *different* address — **and a third party traded the same way in between** | **the shape 25 of 25 real mainnet sandwiches actually used** | three quarters |
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
| **overhead** | **38,805** |

Three SSTOREs per swap, paid by honest flow too. Quoted here rather than left to be discovered.

## A public toxicity signal, not just a fee

The baseline each pool learns is useful to more than the hook that computes it. Everything is
readable by any contract, at the deployed address, today:

| call | answers |
|---|---|
| `currentThreshold(poolId)` | "what counts as an unusual trade *in this pool*" — a live, per-pool number nobody configured |
| `isCalibrated(poolId)` | "has this pool seen enough flow to have an opinion at all" |
| `quote(poolId, trader, zeroForOne, size)` | "what would this exact swap, by this exact address, cost right now" — before sending it |
| `immunity(address)` | "does this address have a confirmed sandwich exit still inside the decay window" |

`quote` is the interesting one. A router can price a swap **before** committing to it, across every
pool the hook serves, and route around the expensive one. A vault can size a rebalance to stay under
a pool's own boundary. An LP can read whether the pool they are in is attracting toxic flow.

That is a different shape of thing from a fee mechanism. The fee is what Antibody does with the
signal; the signal itself is public infrastructure, and the pool-relative threshold is the part that
cannot be obtained anywhere else — a global "large trade" constant is exactly the subjective input
this project exists to remove.

`ToxicFlowDetected` fires on every flagged swap and `BaselineUpdated` on every swap, both consumable
now via [`IAntibodySignal`](contracts/src/interfaces/IAntibodySignal.sol). External routers (CoW,
Flashbots Protect) could consume these to route similar flow privately. Antibody publishes the
signal and stops there — no router integration is claimed, because none was built.

## Layout

```
contracts/
  src/AntibodyHook.sol              the hook
  src/libraries/BaselineMath.sol    EWMA + deviation band, no division, no sqrt
  src/interfaces/IAntibodySignal.sol
  test/                             83 tests
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

- The threshold is **absent** until the 20th swap, not flat at zero. The hook has no opinion and
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

## Measured against real mainnet attacks

Every other attack in this repo was staged by me, against a detector I designed. The obvious
objection is that of course it catches those. So `research/scan_sandwiches.py` walks live Uniswap v3
blocks on Ethereum mainnet, identifies sandwiches by their mechanical signature, and
[the replay test](contracts/test/AntibodyMainnetReplay.t.sol) runs those sequences against the hook.

**610 blocks containing swaps. 25 sandwich-shaped events.**

| detector | real-world hits |
|---|---|
| `SandwichExit` — maximum penalty | **0 of 25** |
| `BlockReversal` — was half penalty | **25 of 25** |
| missed entirely | **0** |

Not one real sandwich was same-origin. Production searchers split entry and exit across separate
addresses precisely to defeat same-origin detection — so the signal carrying the maximum penalty,
and the one every demo here is built on, would not have fired on a single live attack.

`BlockReversal`, the layer built for multi-EOA attackers, caught all of them. The architecture was
right; the pricing was not, so **`BlockReversal` was repriced from half the span to three quarters**.

Resolving the real senders behind those 50 legs shows the evasion is deliberate rather than
incidental: **all 25 exits used a fresh address, and no (entry, exit) pair ever repeated.** Checking
whether they at least reuse a bot contract gives nothing usable either — the most common contract
across the legs is the Uniswap Universal Router, which is what everyone uses. Identity-based defence
does not reach this attacker, which is the honest limit of the cross-pool memory below.

### Two recall numbers, and which one to believe

This page reports both **25 of 25** and **35 of 39**. They are different measurements, not a
before-and-after, and the difference matters:

| measurement | how each block is built | recall |
|---|---|---|
| [replay](contracts/test/AntibodyMainnetReplay.t.sol) | each attack replayed as an isolated 3-swap block: entry, victim, exit, nothing else | 25 of 25 |
| [precision, sample 1](contracts/test/AntibodyPrecision.t.sol) | real blocks with **all** their actual swaps interleaved | 18 of 23 |
| [precision, sample 2](contracts/test/AntibodyPrecision.t.sol) | same, independent 2,500-block scan | 35 of 39 |

Different scans, zero block overlap. The replay presents a textbook sandwich with no other flow
around it, so it measures whether the detector recognises the *shape*. The precision test measures
whether it still recognises it inside real block traffic, which is the condition it will actually
face.

**35 of 39 is the honest headline** — the larger of the two real-block samples. The idealized replay overstates real-world recall, and quoting
it without this caveat would be selecting the friendlier of two tests I ran myself.

### The question recall cannot answer

25 of 25 is *recall*, and recall alone is worth nothing: a detector that fires on every swap also
scores 25 of 25. Precision went unmeasured for six deployments, which mattered, because the
condition as shipped —

```solidity
pl.lastBlock == block.number && pl.lastZeroForOne != zeroForOne && pl.lastTrader != trader
```

— describes a sandwich exit *and* describes two arbitrageurs crossing in a busy block.
[The precision test](contracts/test/AntibodyPrecision.t.sol) replays 117 real mainnet blocks that
contained trading and no sandwich:

Two independently scanned samples, 439 ordinary blocks between them:

| condition | sample | recall | fired on ordinary blocks | precision |
|---|---|---|---|---|
| as shipped | 117 blocks | 23 of 23 | **35** (30%) | 40% |
| as shipped | 322 blocks | 39 of 39 | **133** (41%) | **23%** |
| victim-gated (deployed now) | 117 blocks | 18 of 23 | **0** | **100%** |
| victim-gated (deployed now) | 322 blocks | 35 of 39 | **0** | **100%** |

On the larger sample the shipped detector fired on **41% of all ordinary blocks** and was wrong more
than three times out of four — the same defect as the 23-of-23 false positives further down this
page, wearing a different variable name.

One thing a reader will notice: the comment inside `AntibodyHook.sol` still cites the *first*
sample: a 298-block denominator, and 40% precision. That is deliberate. Solidity embeds a hash of the source in the
deployed bytecode's metadata, so editing even a comment would desync this repo from the
[Uniscan-verified source](https://sepolia.uniscan.xyz/address/0x0f7b23B7d0E798a551c5F584aE2696eea5B8e0c0#code).
The deployed source is frozen at what was deployed; the larger measurement lives here and in the
tests, which is where a number that keeps moving belongs.

One correction worth recording: the first version of `build_fixture.py` excluded *same-origin*
sandwiches from its ground truth, which mislabelled a real attack as an ordinary block and scored
the detector as wrong for catching it. Fixed, and both fixtures relabelled. Exactly 1 of the 39
sandwiches in the larger sample was same-origin — so same-origin sandwiches do occur on mainnet,
they are simply rare, which is a slight refinement of the 0-of-25 finding above.

Requiring a victim in between removes all 35 false positives and costs 5 of 23 detections. Those 5
are unrecoverable by a hook: `afterSwap` sees one swap and two storage words, not the whole block.
An offline pass with the full block in view keeps all 23 at zero false positives, and that is simply
not a thing a hook can run. The trade was taken deliberately — over-charging an honest trader is the
failure this project exists to argue against, and a missed attack costs the pool nothing it was not
already losing.
Not to the maximum: same-origin is *proof* of common control while a pool-level reversal is
*inference*, and charging identically for proof and inference would be sloppy.

**585 of the 610 blocks had swap activity and no sandwich shape at all**, which is the evidence that
the pattern is specific rather than constant — a false-positive measurement taken from data I did
not author.

Profit is deliberately not modelled. Those pools are v2/v3 with static fees and different liquidity
mechanics, so any "Antibody would have taken $X from these attackers" figure would be a guess dressed
as evidence. Detection is a classification question, and that is the only question answered.

## Properties, not just examples

The unit suite proves the hook behaves correctly in situations I constructed. That is exactly the
assurance that failed twice here — the calibration-contamination bug and the Sybil donor hole both
survived a passing suite, because no test I wrote happened to build the shape that exposed them.

So six properties are asserted under stateful fuzzing instead: **128 runs, 8,192 random calls each**,
across four pools and six actors performing swaps, sandwiches, round trips and elapsed time in
orderings nobody designed.

| property | why it matters |
|---|---|
| the fee never exceeds the ceiling | otherwise "this cannot become a confiscation device" is false |
| a quote never falls below base | otherwise the hook can be used to obtain a discount |
| **a swap never reverts** | the benign-failure guarantee — a false positive costs a fee, not access |
| an uncalibrated pool publishes nothing | no opinion it hasn't earned, in any reachable state |
| a vaccinated pool always has a usable baseline | inheritance never produces a half-initialised pool |
| an expired record costs nothing | memory stays memory; the mark can never become permanent |

**Zero reverts across every run.** A campaign that never reaches the interesting branches would pass
all six vacuously, so the suite also asserts afterwards that each run actually completed sandwiches
and round trips.

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

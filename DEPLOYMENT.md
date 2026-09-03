# Antibody — Live Deployment

**Project ID: `HK-UHI10-1010`** · Unichain Sepolia (chain 1301) · Aug 13, 2026

Every address and transaction below is real and verifiable, and the hook's **source is published**
— the explorer shows Solidity, not bytecode, so nothing here has to be taken on trust. Explorer: https://sepolia.uniscan.xyz

---

## Addresses

| | |
|---|---|
| **AntibodyHook** | [`0x747E6584C01C1BA6f11652f97E2C99F42dD1e0C0`](https://sepolia.uniscan.xyz/address/0x747E6584C01C1BA6f11652f97E2C99F42dD1e0C0) |
| Pool ID | `0xda2680d831a88cccccd350ef53890e3d8c85beca7841f7d46eedac46eb4446e9` |
| Demo token 0 (ABDA) | `0x2975200DA18f21bF8ecE746Bed6281e4B373D548` |
| Demo token 1 (ABDB) | `0x5906F35B86A6AC0281A5655933eE37253aA42ef4` |
| Owner / deployer | `0x3Be7fbBDbC73Fc4731D60EF09c4BA1A94DC58E41` |
| v4 PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| v4 Swap Router | `0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba` |

The hook address encodes its permissions in its low bits: `0x…e0c0 & 0x3FFF = 0x20C0` =
`BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`, matching `getHookPermissions()`. Salt mined with
`HookMiner` against the canonical CREATE2 proxy. The pool is initialised with `DYNAMIC_FEE_FLAG`;
without it the PoolManager would silently discard every fee the hook computes, so
`_beforeInitialize` rejects any other configuration outright.

> Earlier hooks (`0xFd99…a0c0`, `0xea0e…a0c0`, `0x1A73…A0c0`) are still on chain and should be
> ignored. The first two carry the defects described under
> [What the live deployment caught](#what-the-live-deployment-caught); the third predates cross-pool
> immunity.

---

## The baseline learned itself, on chain

26 ordinary swaps, constant size and direction, one address:

| after | swaps seen | mean size ratio | deviation | threshold |
|---|---|---|---|---|
| 19 swaps | 19 | 0.0895% | 0.0280% | *none — uncalibrated* |
| 26 swaps | 26 | 0.0895% | **0.0178%** | **0.1429%** |

Below `minSamples` the threshold does not exist — the hook reports no opinion rather than one it
hasn't earned. The deviation then *tightens* as consistent flow arrives, narrowing the band around
a calm regime. **Zero of those 26 swaps were flagged.**

---

## Vaccination, proven on chain

Pool B was created after pool A had characterised the pair. At the moment of creation, with **zero
swaps ever observed**:

| | |
|---|---|
| `vaccinated(poolB)` | **true** |
| `isCalibrated(poolB)` | **true** |
| threshold | **0.1429%** |
| donor's threshold | **0.1429%** — identical |
| `sampleCount` | 20 (`minSamples`, not the donor's 26) |

A 2.0 swap quoted against it on its first block returns `SizeAnomaly` at the **5.00% ceiling**. The
same swap against an unvaccinated fresh pool pays **0.30%**, because nothing is watching yet —
a 16.7x difference on swap one.

The sample count is deliberately the minimum rather than the donor's. Claiming the donor's count
would assert swaps this pool never saw. `vaccinated` stays true permanently, so an integrator can
always tell an inherited opinion from an earned one.

## A real sandwich, caught

All three legs in **block 59892284**.

| leg | signal | penalty | tx |
|---|---|---|---|
| front-run (attacker) | `SizeAnomaly` | +4.11% | [`0xdd453893…`](https://sepolia.uniscan.xyz/tx/0xdd453893a80f05cb5ea2e53ff64d410e2347f5e09e83d2f36d060385345ea50b) |
| **victim** | **none — not flagged** | **0** | [`0x81ec9ac8…`](https://sepolia.uniscan.xyz/tx/0x81ec9ac8f90d3f6c8abb2dbb32835778cc76f78a06c183a8182a880d7c71ee47) |
| **exit (attacker)** | **`SandwichExit`** | **+4.70% (ceiling)** | [`0xd01772e4…`](https://sepolia.uniscan.xyz/tx/0xd01772e430377bf51c9832f686b2e5e49fdf34e85f72c3efb9641424f41ecb16) |

The attacker's exit pays **16.7x** the base fee, paid to the pool's LPs through the native
dynamic-fee override. The victim pays nothing extra.

## Cross-pool immunity, proven live

Two addresses quoted against **pool B**, which has never seen either of them, for an identical
0.1 token0 swap:

| | signal | fee |
|---|---|---|
| `0x00000000…dEaD` — never attacked | `None` | **0.30%** |
| `0xc2Faf652…5b35` — sandwiched pool A | `CrossPoolMemory` | **0.80%** |

The only difference is one confirmed `SandwichExit` in
[block 59892284](https://sepolia.uniscan.xyz/block/59892284), **in pool A**. Before that attack both
addresses quoted identically at 0.30% with an empty record — captured on chain before the sandwich
ran, precisely so the comparison is a measurement rather than an assertion.

The surcharge observed was `4994` against a `5000` step: one confirmed exit, decayed by the six
blocks elapsed between the attack and the quote. It reaches exactly zero at 50,000 blocks.

### Negative results, kept on purpose

A detector that only ever gets shown its hits proves nothing.

- **Legs five blocks apart** (an earlier run): the exit was classified `SizeAnomaly`, not
  `SandwichExit`. Correct — five blocks apart is not a sandwich. The penalty was `47734`, and the
  `734` is exactly `23500 >> 5`: the recency surcharge at five blocks' distance, visible in a real
  transaction.
- **Legs in one block but the victim ordered last** (block 59766707): also `SizeAnomaly`. Also
  correct — with no third party *between* the two legs it is a round trip, not a sandwich.
- **Sequencers pack consecutive nonces adjacently.** The attacker's two legs use consecutive nonces
  from one account, so an evenly spaced publish reliably produced front-run → exit → victim, with
  nobody in between — a round trip the detector correctly refused to call a sandwich. It took an
  asymmetric stagger (victim at +50ms, exit held to +450ms) to get a third party ordered between the
  legs while all three still landed in one block. Three attempts were needed for the run that
  counted, and the two that missed are as much a part of the record as the one that hit.

---

## What the live deployment caught

Three defects that the test suite had not. All three were found by running against a real chain,
and all three are fixed and regression-tested.

### 1. Every calibration swap was flagged as a sandwich

The first deployment classified **23 of 23** ordinary calibration swaps as `SandwichExit` at the
maximum penalty.

`Signal.SandwichExit` was defined as *same trader, same block, opposite direction*. The calibration
script alternated direction to keep the price from drifting, and `forge script` broadcasts without
advancing blocks — so consecutive opposite-direction swaps from one address landed in a single
block and matched that rule exactly.

The rule was wrong, not just the script. **A sandwich is defined by its victim:** attacker buys, a
third party fills at the worsened price, attacker sells. Without an intervening trade there is
nobody to extract from — the position simply opened and closed, which is ordinary behaviour for a
rebalancing market maker or a multi-hop route that revisits the same pool. `SandwichExit` now
additionally requires that a *different* address traded the pool in the same block.

The test suite missed this because every calibration helper called `vm.roll` between swaps, so the
same-block case never arose. The tests were proving something narrower than they appeared to.
Regression tests now cover both the round-trip and the alternating-direction cases directly.

**After the fix: 26 calibration swaps, zero flagged.**

### 2. The emitted penalty could exceed the chargeable ceiling

An exit reported a penalty of `70500` against a `47000` ceiling. The anomaly component was capped,
then the recency surcharge was added *after* the cap.

No swap was ever overcharged — `_beforeSwap` clamps the final fee independently. But
`ToxicFlowDetected` is the public signal this hook exists to publish, and any router or dashboard
consuming it would have read a number the chain never charged. The cap now applies to the sum.

### 3. Sizing the demo victim revealed a real property

With a properly tight baseline, the demo's 0.5 ether victim trade was itself flagged as a size
anomaly — it was genuinely 5x the pool's norm. The demo now uses a victim trade inside the
calibrated band, but the underlying property is real and worth stating: **`SizeAnomaly` prices
anomalous size regardless of who you are.** A sandwich victim making an unusually large trade will
pay the anomaly fee. Only the structural detectors distinguish attacker from victim.

---

## Reproducing

```bash
cd contracts
cp .env.example .env          # fill in PRIVATE_KEY, TOKEN0, TOKEN1, HOOK_ADDRESS

forge script script/00_DeployHook.s.sol                --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/00b_DeployTestTokens.s.sol         --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/00c_SetupDemoActors.s.sol          --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/01_CreatePoolAndAddLiquidity.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/02_Calibrate.s.sol                 --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast

./script/demo/sandwich-same-block.sh                   # the attack
forge script script/04_Inspect.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
```

`sandwich-same-block.sh` is a shell script rather than a forge script for a substantive reason:
`forge script` waits for each receipt before sending the next, spreading the legs across blocks and
making `SandwichExit` unreachable by construction. Even three sequential `cast send` calls split
them, because each does a network round trip before signing. The shell version signs all three
offline, then publishes them 50ms apart — enough to fix arrival order (the victim must land
*between* the attacker's legs), far short of a ~1s block.

Co-location is probable, not guaranteed: a public testnet has no bundle endpoint. The script
reports the actual blocks and states plainly whether the strong detector fired.

---

## Adversarial findings, and what changed

Two holes found by tests written to attack the design rather than confirm it. Both were real, both
are fixed, and the tests that proved them are now regression tests.

### Donor eligibility was Sybil-able, and the slot was permanent

`pairDonor` was written once, when the first pool on a pair was created, and never revisited. Pool
creation is permissionless, and "earned" meant nothing more than twenty swaps having happened. So
an attacker could create the first pool on a pair, trade against themselves twenty times at a size
of their choosing, and every honest pool created afterwards would inherit a band wide enough that
the anomaly detector never fired. **A test confirmed a 50x-typical trade paying base fee in the
victim pool** — not a degraded defence, a disabled one.

Qualification now costs breadth, time and history: a donor must have served `MIN_DONOR_TRADERS`
distinct addresses, be at least `MIN_DONOR_AGE` blocks old, and hold an earned baseline. More
importantly the slot is no longer permanent — a pool serving more distinct traders displaces the
incumbent, so squatting is defeated by ordinary usage rather than by anything the hook must detect.

**Residual risk, stated plainly:** an attacker willing to fund five addresses and wait ~90 minutes
still qualifies. What they cannot do is *hold* the slot once a real pool exists. There is a test
that asserts exactly this rather than claiming the attack is impossible.

### A bystander was being convicted as a victim

`SandwichExit` required a third party between the attacker's two legs, but did not care which way
that third trade ran. A round trip closed across an *opposite*-direction trade was therefore
recorded as a sandwich, when in fact the trader lost to that trade rather than extracted from it.

The intervening trade must now run the same direction as the entry, which is the configuration
where the sandwich payoff actually exists.

**What deliberately still fires:** a round trip closed across a *same*-direction trade. Whatever
the trader intended, the middle trade pushed price the way their entry already had and they closed
against it — that is extraction by its economics, and intent is not observable on chain. An
arbitrageur who closes a loop through one pool across intervening same-direction flow will pay.

## What happens to an honest arbitrageur

Every attack demonstration here uses a deliberate attacker, which proves the mechanism works on the
case it was built for and says nothing about the case it wasn't. So this was run against the live
deployment with a funded address behaving like a legitimate multi-pool arbitrageur, and the verdict
read off the hook rather than argued from tests.

`script/demo/honest-arbitrageur.sh` reproduces it.

**Cross-pool arbitrage is not flagged.** Three rounds — buy A / sell B, then the reverse, then an
immediate repeat — all with both legs landing in the *same block*, published in parallel
specifically so the easy split-block case could not be mistaken for the answer. Result: zero
confirmed exits recorded, and the arbitrageur pays the 0.30% base fee in both pools afterwards.
Each pool sees one leg in one direction, so no same-trader reversal exists for the structural
detector to find.

**A same-pool round trip is flagged, and that is deliberate.** When the same address opened and
closed a position in one pool with a third party's same-direction trade in between, it was recorded
as a confirmed exit. Whatever was intended, the middle trade pushed price the way the entry already
had and the position closed against it — that is the sandwich payoff by its economics, and intent
is not observable on chain. A trade running the *other* way does not trigger it, because there the
trader lost to the middle trade rather than extracted from it.

**The cost of being caught, measured.** After one such round trip the address paid **0.80% in a pool
it had never traded**, against 0.30% for a clean address making the identical swap — 2.66x — and
the same in the pool where it happened. That surcharge decays to nothing over the immunity window
(~14 hours at these block times).

So the honest statement is narrow: an arbitrageur working across pools is unaffected. An
arbitrageur who closes a loop through a single pool across intervening same-direction flow is
priced as an extractor, in every pool, until the memory decays. That is a real cost imposed on a
possibly-legitimate actor, and it is the sharpest edge in the design.

## Questions worth answering

### Why not just use a private RPC?

Flashbots Protect and MEV-Blocker let a trader skip the public mempool and never be sandwiched at
all, client-side, with no hook involved. For a trader who uses one, that is strictly better
protection than Antibody offers, and pretending otherwise would be silly.

Three things it does not do.

It does not protect anyone who did not opt in. Private RPCs are per-trader and adoption is
partial — the flow that arrives at a pool through a public route is exactly the flow that gets
sandwiched, and that flow is not going away.

It does not recover anything for liquidity providers. A private RPC prevents extraction from the
trader; it does not turn attempted extraction into LP revenue. Antibody's penalty accrues through
the pool's own fee growth, so a sandwich attempt against a protected pool pays the LPs. That is a
different beneficiary, and it is the one that decides whether a pool is worth providing liquidity
to.

And it does not travel. Protection ends where the trader's RPC choice ends. Antibody's memory is
held against the attacker at the pool level, so it applies to every trade that reaches the pool
regardless of how it got there.

The honest framing: these are complements, not substitutes. A trader on a private RPC plus a pool
running Antibody is better off than either alone.

### What happens when a genuinely new pair has no donor?

It gets the full cold-start window with no mitigation. Inherited protection only helps a pool whose
pair an established pool has already characterised — the first pool on a brand-new pair earns its
baseline the hard way, exactly as before, and the statistical detector is silent for those first
swaps.

The structural detectors are live from swap one, so a sandwich is still caught during that window.
What is missing is the size-anomaly layer. This is a real boundary of the mechanism rather than
something waiting to be fixed, and no amount of inheritance closes it: the first pool on a pair has
nothing to inherit from by definition.

### If you can't upgrade, how do you fix a bug without resetting everything?

This is the sharpest cost of the design and it deserves a straight answer rather than a dodge.

The hook is immutable on purpose — no owner override, no proxy, no admin key that can change what a
pool has learned. That is what makes "nobody configured these numbers" true rather than a claim
about current intentions.

The price is that a fix means a fresh deployment, and a fresh deployment starts every pool at zero.
Baselines, shared memory, donor eligibility — all of it resets. The network effect that the whole
pitch rests on is precisely the thing that does not survive an upgrade. During this build the
contract was redeployed four times and each one discarded every pool's accumulated history, so this
is not hypothetical.

What makes it survivable rather than fatal: the state is derived, not owned. Nothing is lost that
cannot be re-earned — a pool rebuilds its baseline in tens of swaps, and shared memory rebuilds as
attacks recur. There are no user balances to migrate and no funds stranded, because the hook never
holds any. A migration is slow and embarrassing, not destructive.

What would make it genuinely better is a way for a new deployment to read the previous one's
accumulated state — the same inheritance mechanism that already exists between pools, pointed at a
prior contract instead of a sibling pool. That is a design I would want to build and have not, and
claiming otherwise would be exactly the kind of unearned checkbox this project has already had to
correct twice.

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
Not to the maximum: same-origin is *proof* of common control while a pool-level reversal is
*inference*, and charging identically for proof and inference would be sloppy.

**585 of the 610 blocks had swap activity and no sandwich shape at all**, which is the evidence that
the pattern is specific rather than constant — a false-positive measurement taken from data I did
not author.

Profit is deliberately not modelled. Those pools are v2/v3 with static fees and different liquidity
mechanics, so any "Antibody would have taken $X from these attackers" figure would be a guess dressed
as evidence. Detection is a classification question, and that is the only question answered.

## Precision, measured after six deployments without it

`BlockReversal` shipped as "the pool reversed direction in-block under a different address". That
also describes two arbitrageurs crossing, and nobody had checked how often it did. Replaying 117
real mainnet blocks containing trading and no sandwich:

| condition | sample | recall | fired on ordinary blocks | precision |
|---|---|---|---|---|
| as shipped | 117 blocks | 23 of 23 | 35 (30%) | 40% |
| as shipped | 322 blocks | 39 of 39 | **133 (41%)** | **23%** |
| victim-gated | 117 blocks | 18 of 23 | **0** | **100%** |
| victim-gated | 322 blocks | 35 of 39 | **0** | **100%** |

Two independently scanned samples, 439 ordinary blocks between them. On the larger one the shipped
condition fired on 41% of all ordinary blocks and was wrong more than three times out of four.

The fix mirrors the one already applied to `SandwichExit`: require a third party to have traded the
same direction in between. The hook holds the pool's current in-block *run* — who opened it, and one
further distinct address that joined it — in two storage words, costing **+1,527 gas** per swap
(37,278 → 38,805).

It costs 5 of 23 detections. An offline pass with the whole block in view keeps all 23 at zero false
positives; `afterSwap` cannot run one. `test_sandwichNestedInAnotherTradersRun_isMissed` pins the
specific gap: when the run's opener is *also* the party in the middle, there is no third slot for
them, and the exit reads as the victim closing their own position.

A variant that closes that gap — a sliding window of the last two distinct traders — was written and
measured before being rejected: identical recall on real data, and it reintroduced a false positive.

## Known limitations

- **Cross-pool memory is keyed on `tx.origin`.** A determined attacker rotates addresses and sheds
  the record. This raises the cost of sandwiching across pools; it does not eliminate it.
- **The statistical detector can be desensitised — and here is what that costs, measured.**
  Across three consecutive attack runs on the live pool the learned threshold moved from
  **0.1465% to 2.0357%**, a 14x widening, because the baseline absorbed the attacker's own
  oversized trades as evidence about what this pool considers normal. The third run's front-run
  drew a penalty of only 7,024 pips where the first drew 47,000 — the detector had partly adapted
  to the attacker. This is the limitation working exactly as described rather than a surprise, and
  it is the strongest argument for the structural detectors: `SandwichExit` still fired at the
  ceiling on every run, because it consults no baseline at all. An attacker who repeatedly trades large sizes
  drags the mean and deviation upward, widening "normal" — visible above, where the threshold rose
  from 0.14% to 1.57% across the demo runs. At `alpha = 1/16` this costs on the order of 16 swaps
  of sustained penalty. It does **not** defeat sandwich detection: `SandwichExit` and
  `BlockReversal` are structural and consult no baseline.
- **`SizeAnomaly` does not distinguish attacker from victim.** See defect 3 above.
- **Detection is at the exit, not the entry.** The victim's fill has already occurred. Antibody
  makes sandwiching unprofitable, not impossible.
- **Multi-EOA attackers** are caught by the weaker pool-level detector at half penalty, because
  same-block reversal under two addresses is indistinguishable from honest arbitrage.
- **~37.3k gas** added to every swap, honest flow included.

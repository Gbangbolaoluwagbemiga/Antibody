# Antibody — Live Deployment

**Project ID: `HK-UHI10-1010`** · Unichain Sepolia (chain 1301) · Aug 13, 2026

Every address and transaction below is real and verifiable. Explorer: https://sepolia.uniscan.xyz

---

## Addresses

| | |
|---|---|
| **AntibodyHook** | [`0x1A73Df4cB64A09262845eE7cC0Bc68512bCdA0c0`](https://sepolia.uniscan.xyz/address/0x1A73Df4cB64A09262845eE7cC0Bc68512bCdA0c0) |
| Pool ID | `0x5e10d00c9a2b84ff3e78186bd976d00133445ee479d7489abf65398a12ded0a9` |
| Demo token 0 (ABDA) | `0x2975200DA18f21bF8ecE746Bed6281e4B373D548` |
| Demo token 1 (ABDB) | `0x5906F35B86A6AC0281A5655933eE37253aA42ef4` |
| Owner / deployer | `0x3Be7fbBDbC73Fc4731D60EF09c4BA1A94DC58E41` |
| v4 PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| v4 Swap Router | `0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba` |

The hook address encodes its permissions in its low bits: `0x…a0c0 & 0x3FFF = 0x20C0` =
`BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`, matching `getHookPermissions()`. Salt mined with
`HookMiner` against the canonical CREATE2 proxy. The pool is initialised with `DYNAMIC_FEE_FLAG`;
without it the PoolManager would silently discard every fee the hook computes, so
`_beforeInitialize` rejects any other configuration outright.

> Two earlier hooks (`0xFd99…a0c0`, `0xea0e…a0c0`) are still on chain and should be ignored. They
> carry the defects described under [What the live deployment caught](#what-the-live-deployment-caught).

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

## A real sandwich, caught

All three legs in **block 59767385**.

| leg | signal | penalty | tx |
|---|---|---|---|
| front-run (attacker) | `SizeAnomaly` | +4.11% | [`0x6024ee3d…`](https://sepolia.uniscan.xyz/tx/0x6024ee3d7037f7d140f06da5e681bc0e6bf0805fb63de4879273fb9c40cc4269) |
| **victim** | **none — not flagged** | **0** | [`0x6add1d94…`](https://sepolia.uniscan.xyz/tx/0x6add1d94591594a04c2c37211ae75d63a979d03c1eec3442bf1fe3deb76113f3) |
| **exit (attacker)** | **`SandwichExit`** | **+4.70% (ceiling)** | [`0xdaf90907…`](https://sepolia.uniscan.xyz/tx/0xdaf9090742817557eca35887c0d09e99f506ecffc2aac2e4d8de57714684df7e) |

The attacker's exit pays **16.7x** the base fee, paid to the pool's LPs through the native
dynamic-fee override. The victim pays nothing extra.

### Negative results, kept on purpose

A detector that only ever gets shown its hits proves nothing.

- **Legs five blocks apart** (an earlier run): the exit was classified `SizeAnomaly`, not
  `SandwichExit`. Correct — five blocks apart is not a sandwich. The penalty was `47734`, and the
  `734` is exactly `23500 >> 5`: the recency surcharge at five blocks' distance, visible in a real
  transaction.
- **Legs in one block but the victim ordered last** (block 59766707): also `SizeAnomaly`. Also
  correct — with no third party *between* the two legs it is a round trip, not a sandwich.

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

## Known limitations

- **The statistical detector can be desensitised.** An attacker who repeatedly trades large sizes
  drags the mean and deviation upward, widening "normal" — visible above, where the threshold rose
  from 0.14% to 1.57% across the demo runs. At `alpha = 1/16` this costs on the order of 16 swaps
  of sustained penalty. It does **not** defeat sandwich detection: `SandwichExit` and
  `BlockReversal` are structural and consult no baseline.
- **`SizeAnomaly` does not distinguish attacker from victim.** See defect 3 above.
- **Detection is at the exit, not the entry.** The victim's fill has already occurred. Antibody
  makes sandwiching unprofitable, not impossible.
- **Multi-EOA attackers** are caught by the weaker pool-level detector at half penalty, because
  same-block reversal under two addresses is indistinguishable from honest arbitrage.
- **~34.7k gas** added to every swap, honest flow included.

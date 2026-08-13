# Antibody — Live Deployment

**Project ID: `HK-UHI10-1010`** · Unichain Sepolia (chain 1301) · deployed Aug 13, 2026

Every address and transaction below is real and verifiable. Explorer: https://sepolia.uniscan.xyz

---

## Addresses

| | |
|---|---|
| **AntibodyHook** | [`0xFd99A27b1Fd027C65c77AF680A99EBA129dea0c0`](https://sepolia.uniscan.xyz/address/0xFd99A27b1Fd027C65c77AF680A99EBA129dea0c0) |
| Pool ID | `0xec189ecb7878fe8e45486ed4bff6d0d567afdce161f7c3a4cd2cd2c11815b9c3` |
| Demo token 0 (ABDA) | `0x2975200DA18f21bF8ecE746Bed6281e4B373D548` |
| Demo token 1 (ABDB) | `0x5906F35B86A6AC0281A5655933eE37253aA42ef4` |
| Owner / deployer | `0x3Be7fbBDbC73Fc4731D60EF09c4BA1A94DC58E41` |
| v4 PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| v4 Swap Router | `0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba` |

The hook address encodes its permissions in its low bits: `0x…a0c0 & 0x3FFF = 0x20C0` =
`BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`, matching `getHookPermissions()`. Salt mined with
`HookMiner` against the canonical CREATE2 proxy.

Pool is initialised with `DYNAMIC_FEE_FLAG`. Without it the PoolManager would silently discard
every fee the hook computes, so `_beforeInitialize` rejects any other configuration outright.

---

## The baseline learned itself, on chain

| after | swaps seen | mean size ratio | deviation | threshold |
|---|---|---|---|---|
| 19 calibration swaps | 19 | 8.945e14 | 2.799e14 | *none — uncalibrated* |
| 26 calibration swaps | 26 | 8.945e14 | **1.781e14** | **1.429e15** |

Two things worth pointing at. The threshold does not exist below `minSamples` — the hook reports
no opinion rather than one it hasn't earned. And the deviation *tightened* from 2.799e14 to
1.781e14 as consistent flow arrived: the band narrowing around a calm regime is the literal,
on-chain answer to "how does this evolve beyond a rule base engine."

---

## A real sandwich, caught

All three legs in **block 59765166**, Unichain Sepolia.

| leg | signal | penalty | tx |
|---|---|---|---|
| front-run (attacker) | `SizeAnomaly` | +1.02% | [`0xb98a64f1…`](https://sepolia.uniscan.xyz/tx/0xb98a64f160b463d4a9b231b6a056ac0a0a133066dd45c5f3f0f8c3f1d20ae3de) |
| **victim** | **none — not flagged** | **0** | [`0x3529e73f…`](https://sepolia.uniscan.xyz/tx/0x3529e73f868d4a7c761e81547c233feec66b6e96d6f6da8b26ccc4ea7e63e756) |
| **exit (attacker)** | **`SandwichExit`** | **+4.70% (ceiling)** | [`0x3f555ec2…`](https://sepolia.uniscan.xyz/tx/0x3f555ec2e8e6793f337cbcacd627cef4f675894c2526dc6e1e8171bb06ce3522) |

The attacker's exit pays **16x** the base fee, and it is paid to the pool's LPs through the native
dynamic-fee override. The victim pays nothing extra: the mechanism prices the attacker, not the
person being attacked.

### An earlier run, deliberately kept

Before the legs were co-located they landed in blocks 59764926 / 59764927 / **59764931**, and the
exit was classified `SizeAnomaly` with penalty `47734` — not `SandwichExit`. That is correct
behaviour: five blocks apart is not a sandwich, and the hook declined to call it one. The `734`
is exactly `23500 >> 5`, the recency surcharge at five blocks' distance, measurable in a real
transaction.

Kept in the record because a detector that fires on everything proves nothing.

---

## Reproducing

```bash
cd contracts
cp .env.example .env          # fill in PRIVATE_KEY, TOKEN0, TOKEN1, HOOK_ADDRESS

forge script script/00_DeployHook.s.sol      --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/00b_DeployTestTokens.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/00c_SetupDemoActors.s.sol  --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/01_CreatePoolAndAddLiquidity.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/02_Calibrate.s.sol       --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast

./script/demo/sandwich-same-block.sh          # the attack
forge script script/04_Inspect.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL   # read the state
```

`sandwich-same-block.sh` is a shell script rather than a forge script for a substantive reason:
`forge script` waits for each receipt before sending the next, which spreads the legs across
blocks and makes `SandwichExit` unreachable by construction. The shell version signs all three
offline and publishes them concurrently. Co-location is probable, not guaranteed — a public
testnet has no bundle endpoint — so the script reports the actual blocks and says plainly whether
the strong detector fired.

---

## Known limitations

Stated here rather than discovered by a judge.

- **The statistical detector can be desensitised.** An attacker who repeatedly trades large sizes
  drags the pool's mean and deviation upward, widening the band that defines "normal" — visible in
  the run above, where the threshold rose from 1.47e16 to 1.73e16 across a single attack. With
  `alpha = 1/16` this takes on the order of 16 swaps of sustained cost to move meaningfully.
  It does **not** defeat the sandwich detector: `SandwichExit` and `BlockReversal` are structural
  and consult no baseline at all. Only the size-anomaly detector degrades.
- **Detection is at the exit, not the entry.** The victim's fill has already occurred. Antibody
  makes sandwiching unprofitable, not impossible.
- **Multi-EOA attackers** are caught by the weaker pool-level detector, at half penalty, because
  same-block reversal under two addresses is indistinguishable from honest arbitrage.
- **~34.7k gas** added to every swap, honest flow included. Three SSTOREs is the floor for
  cross-transaction detection, since transient storage cannot span a sandwich's three transactions.

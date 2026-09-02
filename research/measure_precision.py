#!/usr/bin/env python3
"""
Measure BlockReversal's FALSE POSITIVE rate against real mainnet blocks.

WHY THIS EXISTS
---------------
The replay in AntibodyMainnetReplay.t.sol answers "does the detector catch real attacks" and the
answer is 25 of 25. That is recall, and recall alone is worthless: a detector that fires on every
swap also scores 25 of 25.

The question never asked was precision -- how often does it fire on ordinary trading? That matters
here more than usual, because the condition as deployed is:

    pl.lastBlock == block.number && pl.lastZeroForOne != zeroForOne && pl.lastTrader != trader

which is a fair description of a sandwich exit AND a fair description of two arbitrageurs trading
opposite ways in a busy block. This project has already shipped one detector that could not tell an
attack from ordinary behaviour (23 of 23 false positives on live chain). Not checking the second one
against real data would be the same mistake with a different variable name.

GROUND TRUTH
------------
A block "contains a sandwich" if it has the mechanical shape: an entry, at least one different
address trading the same direction after it, and an exit in the opposite direction. That is a
definition, not an oracle -- it is the same one scan_sandwiches.py uses, stated so it can be argued
with rather than hidden.

WHAT IS SIMULATED
-----------------
The hook's per-pool state walked forward one swap at a time, exactly as afterSwap would see it:
lastBlock, lastTrader, lastZeroForOne. If the deployed condition would fire on a block with no
sandwich shape in it, that is a false positive and it is counted.
"""
import json, sys, subprocess, collections

RPC = "https://eth.drpc.org"
POOL = (sys.argv[2] if len(sys.argv) > 2 else "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640").lower()
SWAP_TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"

def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    out = subprocess.run(["curl", "-s", "-m", "60", "-X", "POST", RPC,
                          "-H", "content-type: application/json", "-d", body],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"error": {"message": out[:120] or "empty"}}

def s256(h):
    v = int(h, 16)
    return v - (1 << 256) if v >= (1 << 255) else v

def swaps_by_block(a, b):
    r = rpc("eth_getLogs", [{"address": POOL, "topics": [SWAP_TOPIC],
                             "fromBlock": hex(a), "toBlock": hex(b)}])
    if "error" in r:
        print(f"  rpc error: {r['error'].get('message')}", file=sys.stderr); return {}
    by = collections.defaultdict(list)
    for log in r["result"]:
        by[int(log["blockNumber"], 16)].append({
            "tx": log["transactionHash"],
            "logIndex": int(log["logIndex"], 16),
            "zeroForOne": s256(log["data"][2:][0:64]) > 0,
        })
    return by

def origins_for(bn):
    r = rpc("eth_getBlockByNumber", [hex(bn), True])
    if "error" in r or not r.get("result"): return {}
    return {t["hash"]: t["from"].lower() for t in r["result"]["transactions"]}

def has_sandwich_shape(swaps):
    for i, entry in enumerate(swaps):
        for j in range(i + 1, len(swaps)):
            ex = swaps[j]
            if ex["zeroForOne"] == entry["zeroForOne"]:
                continue
            victims = [m for m in swaps[i+1:j]
                       if m["origin"] not in (entry["origin"], ex["origin"])
                       and m["zeroForOne"] == entry["zeroForOne"]]
            if victims:
                return True
    return False

def block_reversal_fires(swaps):
    """The deployed condition, walked forward exactly as the hook sees it."""
    last_trader, last_dir = None, None
    for s in swaps:
        if last_trader is not None and s["zeroForOne"] != last_dir and s["origin"] != last_trader:
            return True
        last_trader, last_dir = s["origin"], s["zeroForOne"]
    return False

def victim_gated_fires(swaps):
    """
    The candidate fix: require a third party to have traded in between, the same way SandwichExit
    was repaired. Measured here before it is written into Solidity.
    """
    for j in range(len(swaps)):
        ex = swaps[j]
        for i in range(j - 1, -1, -1):
            entry = swaps[i]
            if entry["zeroForOne"] == ex["zeroForOne"] or entry["origin"] == ex["origin"]:
                continue
            victims = [m for m in swaps[i+1:j]
                       if m["origin"] not in (entry["origin"], ex["origin"])
                       and m["zeroForOne"] == entry["zeroForOne"]]
            if victims:
                return True
    return False

if __name__ == "__main__":
    head = int(rpc("eth_blockNumber", [])["result"], 16)
    span = int(sys.argv[1]) if len(sys.argv) > 1 else 600
    start, chunk = head - span, 200
    stats = collections.Counter(); rows = []

    while start < head:
        end = min(start + chunk - 1, head)
        by = swaps_by_block(start, end)
        for bn in sorted(by):
            sw = sorted(by[bn], key=lambda s: s["logIndex"])
            og = origins_for(bn)
            if not og: continue
            for s in sw: s["origin"] = og.get(s["tx"], "?")
            sw = [s for s in sw if s["origin"] != "?"]
            if not sw: continue
            stats["blocksWithSwaps"] += 1
            truth = has_sandwich_shape(sw)
            fires = block_reversal_fires(sw)
            gated = victim_gated_fires(sw)
            stats["sandwichBlocks" if truth else "ordinaryBlocks"] += 1
            if fires: stats["fires_TP" if truth else "fires_FP"] += 1
            if gated: stats["gated_TP" if truth else "gated_FP"] += 1
            if truth and not fires: stats["missed"] += 1
            if truth and not gated: stats["gated_missed"] += 1
            rows.append({"block": bn, "swaps": len(sw), "sandwich": truth,
                         "blockReversal": fires, "victimGated": gated})
        print(f"  {start}-{end}: {stats['blocksWithSwaps']} blocks, "
              f"{stats['sandwichBlocks']} sandwich, FP {stats['fires_FP']}", flush=True)
        start = end + 1

    ordinary = stats["ordinaryBlocks"] or 1
    sand = stats["sandwichBlocks"] or 1
    print("\n" + "=" * 62)
    print(f"  blocks with swaps            {stats['blocksWithSwaps']}")
    print(f"  blocks with a sandwich shape {stats['sandwichBlocks']}")
    print(f"  ordinary blocks              {stats['ordinaryBlocks']}")
    print("\n  AS DEPLOYED (no victim required)")
    print(f"    caught      {stats['fires_TP']}/{stats['sandwichBlocks']}  recall {stats['fires_TP']/sand:.1%}")
    print(f"    FIRED ON    {stats['fires_FP']}/{stats['ordinaryBlocks']} ordinary blocks  "
          f"false positive rate {stats['fires_FP']/ordinary:.1%}")
    tp, fp = stats["fires_TP"], stats["fires_FP"]
    print(f"    precision   {tp/(tp+fp):.1%}" if tp + fp else "    precision   n/a")
    print("\n  VICTIM-GATED (candidate fix)")
    print(f"    caught      {stats['gated_TP']}/{stats['sandwichBlocks']}  recall {stats['gated_TP']/sand:.1%}")
    print(f"    fired on    {stats['gated_FP']}/{stats['ordinaryBlocks']} ordinary blocks  "
          f"false positive rate {stats['gated_FP']/ordinary:.1%}")
    tp2, fp2 = stats["gated_TP"], stats["gated_FP"]
    print(f"    precision   {tp2/(tp2+fp2):.1%}" if tp2 + fp2 else "    precision   n/a")
    print("=" * 62)
    json.dump({"pool": POOL, "stats": dict(stats), "blocks": rows},
              open("research/precision.json", "w"), indent=1)
    print("  -> research/precision.json")

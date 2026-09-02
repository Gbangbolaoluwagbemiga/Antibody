#!/usr/bin/env python3
"""
Build an MEVBench fixture from any live Uniswap v3 pool.

WHY
---
MEV hooks report recall ("it caught N attacks") and almost never precision ("it fired on M blocks
that had no attack in them"). Recall alone cannot distinguish a good detector from one that fires on
everything. Antibody's own BlockReversal reported 25-of-25 across six deployments and, measured
properly for the first time, fired on 35 of 117 ordinary blocks.

This produces the ground-truth data that makes the second number computable, from real chain history
rather than staged scenarios.

USAGE
-----
    python3 research/build_fixture.py [--span 600] [--pool 0x...] [--out path.json]

    --span   how many recent blocks to scan (default 600)
    --pool   Uniswap v3 pool address (default USDC/WETH 0.05%, among the most sandwiched on mainnet)
    --rpc    JSON-RPC endpoint (default a public one)
    --out    where to write (default contracts/test/fixtures/mainnet_precision.json)

GROUND TRUTH
------------
A block "contains a sandwich" if it holds the mechanical shape: an entry, at least one *different*
address trading the same direction after it, then a reversal. This is a definition, not an oracle.
It is recorded in the fixture so a reader can disagree with it rather than having to trust it.

Intent is deliberately not inferred. Whether the party in the middle "meant" to be there is
unknowable from chain data; whether they were structurally positioned to be extracted from is not.

ENCODING
--------
Trader indices are local to each block. Only who-is-distinct-from-whom matters, because the harness
replays each block into a fresh block number, so identities cannot carry between them. Blocks with a
single swap are dropped: a reversal needs two, so they cannot change either number and only inflate
the file.

A `sender` in a Swap log is the router, not the person, so true origins come from each block's
transaction list. That is one block fetch rather than one call per swap.
"""
import argparse, collections, json, subprocess, sys

SWAP_TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"


def rpc(endpoint, method, params):
    # curl rather than urllib: public nodes reject Python's default user agent with a 403, which
    # looks exactly like a malformed request until you check.
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    out = subprocess.run(
        ["curl", "-s", "-m", "60", "-X", "POST", endpoint,
         "-H", "content-type: application/json", "-d", body],
        capture_output=True, text=True,
    ).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"error": {"message": out[:160] or "empty response"}}


def signed(word):
    v = int(word, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


def swaps_by_block(endpoint, pool, lo, hi):
    r = rpc(endpoint, "eth_getLogs", [{"address": pool, "topics": [SWAP_TOPIC],
                                       "fromBlock": hex(lo), "toBlock": hex(hi)}])
    if "error" in r:
        print(f"  rpc error: {r['error'].get('message')}", file=sys.stderr)
        return {}
    by = collections.defaultdict(list)
    for log in r["result"]:
        by[int(log["blockNumber"], 16)].append({
            "tx": log["transactionHash"],
            "logIndex": int(log["logIndex"], 16),
            # amount0 > 0 means token0 went into the pool: a sell of token0.
            "zeroForOne": signed(log["data"][2:][0:64]) > 0,
        })
    return by


def origins(endpoint, block_number):
    r = rpc(endpoint, "eth_getBlockByNumber", [hex(block_number), True])
    if "error" in r or not r.get("result"):
        return {}
    return {t["hash"]: t["from"].lower() for t in r["result"]["transactions"]}


def has_sandwich_shape(swaps):
    for i, entry in enumerate(swaps):
        for j in range(i + 1, len(swaps)):
            exit_ = swaps[j]
            # Same-origin and multi-origin sandwiches both count. An earlier version of this
            # skipped same-origin exits, which silently mislabelled real sandwiches as ordinary
            # blocks and then scored the detector as wrong for catching one.
            if exit_["zeroForOne"] == entry["zeroForOne"]:
                continue
            victims = [m for m in swaps[i + 1:j]
                       if m["origin"] not in (entry["origin"], exit_["origin"])
                       and m["zeroForOne"] == entry["zeroForOne"]]
            if victims:
                return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--span", type=int, default=600)
    ap.add_argument("--pool", default="0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640")
    ap.add_argument("--rpc", default="https://eth.drpc.org")
    ap.add_argument("--out", default="contracts/test/fixtures/mainnet_precision.json")
    a = ap.parse_args()
    pool = a.pool.lower()

    head = int(rpc(a.rpc, "eth_blockNumber", [])["result"], 16)
    start, kept, dropped = head - a.span, [], 0

    while start < head:
        end = min(start + 199, head)
        for bn, raw in sorted(swaps_by_block(a.rpc, pool, start, end).items()):
            og = origins(a.rpc, bn)
            if not og:
                continue
            sw = [{"origin": og.get(s["tx"], "?"), "zeroForOne": s["zeroForOne"]}
                  for s in sorted(raw, key=lambda s: s["logIndex"])]
            sw = [s for s in sw if s["origin"] != "?"]
            if len(sw) < 2:
                dropped += 1
                continue
            local = {}
            for s in sw:
                local.setdefault(s["origin"], len(local))
            kept.append({"block": bn, "sandwich": has_sandwich_shape(sw),
                         "t": [local[s["origin"]] for s in sw],
                         "d": [1 if s["zeroForOne"] else 0 for s in sw]})
        print(f"  ..{end}  ({len(kept)} usable blocks)", flush=True)
        start = end + 1

    doc = {
        "source": f"Ethereum mainnet, Uniswap v3 pool {pool}",
        "groundTruth": "A block counts as containing a sandwich if it holds the mechanical shape: "
                       "an entry, a different address trading the same direction after it, then a "
                       "reversal. A definition, not an oracle -- stated so it can be argued with.",
        "encoding": "t[] are per-block trader indices (only distinctness within a block matters, "
                    "since each block replays into a fresh block number). d[] is zeroForOne as 0/1.",
        "excluded": f"{dropped} blocks holding a single swap. A reversal needs two, so they cannot "
                    "change either number.",
        "blocksKept": len(kept),
        "maxDistinctTradersInABlock": max((len(set(b["t"])) for b in kept), default=0),
        "maxSwapsInABlock": max((len(b["t"]) for b in kept), default=0),
        "sandwichBlocks": sum(1 for b in kept if b["sandwich"]),
        "ordinaryBlocks": sum(1 for b in kept if not b["sandwich"]),
        "blocks": kept,
    }
    with open(a.out, "w") as fh:
        json.dump(doc, fh, indent=1)
    print(f"\n  {doc['sandwichBlocks']} sandwich / {doc['ordinaryBlocks']} ordinary "
          f"({len(kept)} usable, {dropped} single-swap dropped)")
    print(f"  max {doc['maxDistinctTradersInABlock']} distinct traders in a block")
    print(f"  -> {a.out}")


if __name__ == "__main__":
    main()

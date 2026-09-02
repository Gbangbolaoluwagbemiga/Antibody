#!/usr/bin/env python3
"""
Evaluate only conditions a hook can actually evaluate.

measure_precision.py's victim-gated variant looked at the whole block at once. afterSwap cannot do
that -- it sees one swap, plus whatever O(1) state the last swap left behind. A result produced by
an algorithm the contract cannot run is not a result about the contract.

So each candidate below is a forward state machine over the block's swaps, holding a fixed number of
words, exactly as the deployed struct would. Whatever wins here is what gets written into Solidity.
"""
import json, collections

rows = json.load(open("research/precision.json"))
BLOCKS = {b["block"]: b for b in rows["blocks"]}
SEQ = json.load(open("research/sequences.json")) if False else None

def deployed(swaps):
    """A: as shipped. Reversal by anyone other than the immediately preceding trader."""
    lt = ld = None
    for s in swaps:
        if lt is not None and s["zeroForOne"] != ld and s["origin"] != lt:
            return True
        lt, ld = s["origin"], s["zeroForOne"]
    return False

def victim_identity(swaps):
    """B: track the run's opener and one distinct same-direction follower (the victim).
       Fire on a reversal by someone who is not that victim. 3 storage words."""
    blk_dir = opener = victim = None
    for s in swaps:
        if opener is None:
            blk_dir, opener, victim = s["zeroForOne"], s["origin"], None
            continue
        if s["zeroForOne"] == blk_dir:
            if s["origin"] != opener:
                victim = s["origin"]
        else:
            if victim is not None and s["origin"] != victim:
                return True
            blk_dir, opener, victim = s["zeroForOne"], s["origin"], None
    return False

def victim_count_only(swaps):
    """C: same, but keep a flag instead of the victim's address, and exclude the opener.
       2 storage words."""
    blk_dir = opener = None; saw_other = False
    for s in swaps:
        if opener is None:
            blk_dir, opener, saw_other = s["zeroForOne"], s["origin"], False
            continue
        if s["zeroForOne"] == blk_dir:
            if s["origin"] != opener: saw_other = True
        else:
            if saw_other and s["origin"] != opener:
                return True
            blk_dir, opener, saw_other = s["zeroForOne"], s["origin"], False
    return False

def naive_two(swaps):
    """D: cheapest — any reversal after two distinct traders went the same way. 2 words."""
    blk_dir = opener = None; saw_other = False
    for s in swaps:
        if opener is None:
            blk_dir, opener, saw_other = s["zeroForOne"], s["origin"], False
            continue
        if s["zeroForOne"] == blk_dir:
            if s["origin"] != opener: saw_other = True
        else:
            if saw_other: return True
            blk_dir, opener, saw_other = s["zeroForOne"], s["origin"], False
    return False

CANDS = [("A deployed", deployed), ("B victim identity (3 words)", victim_identity),
         ("C victim flag, excl opener (2 words)", victim_count_only),
         ("D any reversal after 2 (2 words)", naive_two)]

blocks = json.load(open("research/blockswaps.json"))
print(f"{'candidate':38} {'recall':>12} {'FP rate':>10} {'precision':>10}")
print("-" * 74)
for name, fn in CANDS:
    tp = fp = fn_ = tn = 0
    for b in blocks:
        truth, fires = b["sandwich"], fn(b["swaps"])
        if truth and fires: tp += 1
        elif truth: fn_ += 1
        elif fires: fp += 1
        else: tn += 1
    sand, ordn = tp + fn_, fp + tn
    print(f"{name:38} {tp:>4}/{sand:<4} {tp/max(sand,1):>5.0%} "
          f"{fp:>4}/{ordn:<5} {fp/max(ordn,1):>4.1%} {tp/max(tp+fp,1):>9.0%}")

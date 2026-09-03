#!/usr/bin/env python3
"""
Fail if any document quotes a number the code no longer produces.

WHY THIS EXISTS
---------------
Three times in this project a find-and-replace silently matched nothing and the edit was reported as
done: DEPLOYMENT.md sat two deployments behind on addresses, the demo script kept a superseded gas
figure, and a false-positive rate never rendered on the site. Each was caught by someone reading
carefully, which is not a control.

Numbers here have a single source of truth -- the deployed hook, the site data built from it, and
the fixtures the tests assert against. This checks the prose against those, so drift fails loudly
instead of shipping.

    python3 scripts/check-consistency.py

DELIBERATE EXCEPTIONS are listed explicitly. A before/after comparison legitimately contains an old
number; the point is that it is declared rather than assumed.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAIL = []

def read(p):
    f = ROOT / p
    return f.read_text() if f.exists() else ""

hist = json.loads(read("frontend/src/data/history.json"))
large = json.loads(read("contracts/test/fixtures/mainnet_precision_large.json"))
small = json.loads(read("contracts/test/fixtures/mainnet_precision.json"))

HOOK = hist["hook"]
GAS = hist["liquidityCase"]["gasOverhead"]
PREC = hist["mainnetPrecision"]

DOCS = ["README.md", "DEPLOYMENT.md", "ARCHITECTURE.md", "PRESETS.md"]
UI = [str(p.relative_to(ROOT)) for p in (ROOT / "frontend/src").rglob("*.tsx")]

def forbid(pattern, why, files, allow=()):
    """No file may contain `pattern`, except those in `allow`."""
    for f in files:
        if f in allow:
            continue
        body = read(f)
        for i, line in enumerate(body.splitlines(), 1):
            if re.search(pattern, line):
                FAIL.append(f"{f}:{i}  {why}\n      {line.strip()[:110]}")

# ── superseded hook addresses ──────────────────────────────────────────────────────────────
forbid(r"0x8Ca88762|0x7BDeB74c|0x1A73Df4c|0x0f7b23B7", "superseded hook address", DOCS + UI)

# ── superseded gas figure. DEPLOYMENT.md states the before/after of the victim gate. ────────
forbid(r"37,?278", f"superseded gas overhead (now {GAS:,})", DOCS + UI,
       allow=("DEPLOYMENT.md",))

# ── superseded precision framing, replaced by the larger sample ────────────────────────────
forbid(r"three fifths", "superseded: the larger sample is more than three quarters", DOCS + UI)
forbid(r"35 of 117|fired on 35\b", "superseded small-sample figure; large sample is 133 of 322",
       DOCS + UI, allow=("README.md", "DEPLOYMENT.md"))

# ── the numbers the site renders must match the fixtures the tests assert ───────────────────
if PREC["ordinaryBlocks"] != large["ordinaryBlocks"]:
    FAIL.append(f"history.json ordinaryBlocks={PREC['ordinaryBlocks']} but the large fixture "
                f"has {large['ordinaryBlocks']}")
if PREC["sandwichBlocks"] != large["sandwichBlocks"]:
    FAIL.append(f"history.json sandwichBlocks={PREC['sandwichBlocks']} but the large fixture "
                f"has {large['sandwichBlocks']}")
if PREC["secondSampleOrdinaryBlocks"] != small["ordinaryBlocks"]:
    FAIL.append(f"history.json secondSample={PREC['secondSampleOrdinaryBlocks']} but the small "
                f"fixture has {small['ordinaryBlocks']}")

# ── the deployed address must appear nowhere stale and everywhere it matters ────────────────
if HOOK.lower() not in read("DEPLOYMENT.md").lower():
    FAIL.append(f"DEPLOYMENT.md does not mention the deployed hook {HOOK}")


if FAIL:
    print(f"\n  {len(FAIL)} consistency problem(s):\n")
    for f in FAIL:
        print(f"    {f}")
    print()
    sys.exit(1)
print(f"  consistent: hook {HOOK[:10]}…, gas {GAS:,}, "
      f"precision 0/{PREC['ordinaryBlocks']} (was {PREC['beforeGateFiredOnOrdinary']})")

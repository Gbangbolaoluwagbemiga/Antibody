#!/usr/bin/env bash
# Prove the repo source compiles to exactly the bytecode deployed on chain.
#
# A verified contract on a block explorer proves the explorer was given source that compiles to the
# deployed bytecode. It does not prove THIS repo still does -- a later edit to a comment changes the
# metadata hash Solidity appends, and the two silently diverge. That happened here: a comment in
# AntibodyHook.sol asserted "zero were same-origin", a larger scan disproved it, and correcting it
# meant redeploying rather than quietly desyncing the repo from the verified source.
#
# Immutables are masked before comparing: the compiler emits zero placeholders for them and the
# constructor writes the real values, so those bytes legitimately differ.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./contracts/.env; set +a
RPC="${UNICHAIN_SEPOLIA_RPC_URL:-https://sepolia.unichain.org}"

cast code "$HOOK_ADDRESS" --rpc-url "$RPC" | tr -d '\n\r ' | tr 'A-F' 'a-f' > /tmp/_onchain.hex
( cd contracts && forge build >/dev/null 2>&1 )

python3 - "$HOOK_ADDRESS" <<'PY'
import json, sys
art = json.load(open("contracts/out/AntibodyHook.sol/AntibodyHook.json"))
a = open("/tmp/_onchain.hex").read().strip().removeprefix("0x")
b = art["deployedBytecode"]["object"].lower().removeprefix("0x")
if len(a) != len(b):
    sys.exit(f"  LENGTH MISMATCH: on-chain {len(a)}, local {len(b)}")
spans = [(r["start"], r["length"])
         for v in art["deployedBytecode"].get("immutableReferences", {}).values() for r in v]
la, lb = list(a), list(b)
for start, length in spans:
    for i in range(start * 2, (start + length) * 2):
        la[i] = lb[i] = "0"
if "".join(la) != "".join(lb):
    sys.exit("  BYTECODE MISMATCH: this repo does not compile to the deployed contract")
print(f"  bytecode matches {sys.argv[1]} exactly ({len(a)//2} bytes, {len(spans)} immutables masked)")
PY

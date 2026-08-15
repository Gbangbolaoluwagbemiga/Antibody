#!/usr/bin/env bash
#
# Antibody — does an honest multi-pool arbitrageur get convicted?
#
# WHY THIS EXISTS
# ---------------
# Every attack demonstration so far used a deliberate attacker, which proves the mechanism works on
# the case it was built for and says nothing about the case it wasn't. The open question is what
# happens to a legitimate arbitrageur: same-block activity, multiple pools, sometimes opposite
# directions — structurally similar to a sandwich, economically not one.
#
# Unit tests already cover the shapes I could think to construct. That is exactly the assurance
# that failed before: a suite that advanced a block between every swap missed a false-positive
# class that only appeared when real transactions landed in the same block on a real chain. So this
# runs the patterns against the live deployment and reads the verdict off the hook.
#
# Three rounds, each a shape a real arbitrageur produces:
#   1. classic two-pool arb — buy in A, sell in B, same block
#   2. reverse direction — sell in A, buy in B
#   3. rapid repeat — the same loop again immediately, to trip any recency component
#
# What matters is the immunity record at the end. If it is still zero, an honest cross-pool
# arbitrageur carries nothing into other pools. If it is not, the limitation is worse than
# documented and belongs in the pitch as such.
set -euo pipefail

cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a

RPC="${UNICHAIN_SEPOLIA_RPC_URL:-https://sepolia.unichain.org}"
ROUTER=0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba
HOOK="$HOOK_ADDRESS"
FEE=8388608
SIZE=${ARB_SIZE:-200000000000000000}   # 0.2 — an ordinary size for these pools
DEADLINE=$(( $(date +%s) + 3600 ))

SIG='swapExactTokensForTokens(uint256,uint256,bool,(address,address,uint24,int24,address),bytes,address,uint256)'
KEY_A="($TOKEN0,$TOKEN1,$FEE,60,$HOOK)"
KEY_B="($TOKEN0,$TOKEN1,$FEE,10,$HOOK)"

echo "arbitrageur: $ARB"
echo "starting immunity: $(cast call "$HOOK" 'immunity(address)(uint32,uint32)' "$ARB" --rpc-url "$RPC" | tr '\n' ' ')"
echo

round() {
  local label=$1 dirA=$2 dirB=$3
  local n; n=$(cast nonce "$ARB" --rpc-url "$RPC")

  # Both legs published together — a real arb wants them atomic-ish, and consecutive nonces keep
  # their relative order regardless of arrival.
  local r1 r2
  r1=$(cast mktx "$ROUTER" "$SIG" "$SIZE" 0 "$dirA" "$KEY_A" 0x "$ARB" "$DEADLINE" \
        --private-key "$ARB_KEY" --nonce "$n" --rpc-url "$RPC" --gas-limit 900000)
  r2=$(cast mktx "$ROUTER" "$SIG" "$SIZE" 0 "$dirB" "$KEY_B" 0x "$ARB" "$DEADLINE" \
        --private-key "$ARB_KEY" --nonce "$((n+1))" --rpc-url "$RPC" --gas-limit 900000)

  # Published in parallel, not sequentially. The question is specifically what happens to
  # same-block cross-pool activity, so a sequential publish that reliably splits the legs would be
  # testing the easy case and reporting it as the answer.
  local tmp; tmp=$(mktemp -d)
  cast publish "$r1" --rpc-url "$RPC" --async > "$tmp/1" 2>&1 &
  cast publish "$r2" --rpc-url "$RPC" --async > "$tmp/2" 2>&1 &
  wait
  local t1 t2
  t1=$(tr -d '[:space:]' < "$tmp/1"); t2=$(tr -d '[:space:]' < "$tmp/2"); rm -rf "$tmp"
  cast receipt "$t1" --rpc-url "$RPC" --confirmations 1 >/dev/null 2>&1 || true
  cast receipt "$t2" --rpc-url "$RPC" --confirmations 1 >/dev/null 2>&1 || true

  local b1 b2
  b1=$(( $(cast receipt "$t1" --rpc-url "$RPC" --json | jq -r '.blockNumber') ))
  b2=$(( $(cast receipt "$t2" --rpc-url "$RPC" --json | jq -r '.blockNumber') ))
  printf '  %-22s pool A blk %s   pool B blk %s   %s\n' "$label" "$b1" "$b2" \
    "$([ "$b1" = "$b2" ] && echo 'same block' || echo 'split')"
}

round "1. buy A / sell B"  true  false
round "2. sell A / buy B"  false true
round "3. repeat buy/sell" true  false

echo
echo "=== verdict ==="
IMM=$(cast call "$HOOK" 'immunity(address)(uint32,uint32)' "$ARB" --rpc-url "$RPC" | head -1)
echo "  confirmed sandwich exits recorded against the arbitrageur: $IMM"

A_ID=$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' "$TOKEN0" "$TOKEN1" $FEE 60 "$HOOK")")
B_ID=$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' "$TOKEN0" "$TOKEN1" $FEE 10 "$HOOK")")
echo "  what they now pay for an ordinary swap:"
echo "    pool A: $(cast call "$HOOK" 'quote(bytes32,address,bool,uint256)(uint8,uint24,uint256,uint256)' "$A_ID" "$ARB" true "$SIZE" --rpc-url "$RPC" | head -2 | tr '\n' ' ')"
echo "    pool B: $(cast call "$HOOK" 'quote(bytes32,address,bool,uint256)(uint8,uint24,uint256,uint256)' "$B_ID" "$ARB" true "$SIZE" --rpc-url "$RPC" | head -2 | tr '\n' ' ')"
echo "  (signal 0 = clean · fee in pips, 3000 = 0.30% base)"

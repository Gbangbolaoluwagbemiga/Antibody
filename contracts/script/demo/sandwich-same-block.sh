#!/usr/bin/env bash
#
# Antibody — live same-block sandwich against Unichain Sepolia.
#
# WHY THIS IS A SHELL SCRIPT AND NOT A FORGE SCRIPT
# --------------------------------------------------
# `forge script` waits for each transaction's receipt before sending the next, so its legs land
# blocks apart — and `Signal.SandwichExit` requires the attacker's two legs to share a block,
# because that is precisely what distinguishes a sandwich from two ordinary trades. A forge-driven
# attack therefore cannot exercise the detector this project is built around.
#
# WHY SIGN-THEN-PUBLISH RATHER THAN THREE `cast send` CALLS
# ---------------------------------------------------------
# `cast send` does a network round trip (nonce, gas, chain id) before it signs, so three of them in
# sequence spread over ~1-2s — which on a 1s-block chain is exactly enough to split them. So all
# three are signed offline first, then published concurrently. Submission spread drops from
# hundreds of milliseconds to roughly nothing.
#
# Leg ordering is guaranteed where it matters: the attacker's two legs use consecutive nonces from
# one account, so the chain cannot execute the exit before the entry regardless of arrival order.
# The victim's trade is a separate account; it makes the narrative legible but the detector does
# not depend on it.
#
# Still best-effort, not deterministic: a public testnet offers no bundle endpoint, so co-location
# is probable rather than guaranteed. The script reports the block each leg actually landed in and
# states plainly whether the strong detector fired. Re-run if they split.
#
set -euo pipefail

cd "$(dirname "$0")/../.."   # -> contracts/
set -a; . ./.env; set +a

RPC="${UNICHAIN_SEPOLIA_RPC_URL:-https://sepolia.unichain.org}"
ROUTER=0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba
POOL_FEE=8388608   # LPFeeLibrary.DYNAMIC_FEE_FLAG
TICK_SPACING=60

ATTACK_SIZE=${ATTACK_SIZE:-2000000000000000000}   # 2.0
VICTIM_SIZE=${VICTIM_SIZE:-100000000000000000}    # 0.1 — matches the calibrated norm exactly
DEADLINE=$(( $(date +%s) + 3600 ))

SIG='swapExactTokensForTokens(uint256,uint256,bool,(address,address,uint24,int24,address),bytes,address,uint256)'
POOLKEY="($TOKEN0,$TOKEN1,$POOL_FEE,$TICK_SPACING,$HOOK_ADDRESS)"

AN=$(cast nonce "$DEMO_ATTACKER" --rpc-url "$RPC")
VN=$(cast nonce "$DEMO_VICTIM" --rpc-url "$RPC")

echo "Signing three legs offline..."
echo "  attacker $DEMO_ATTACKER  nonces $AN, $((AN+1))"
echo "  victim   $DEMO_VICTIM  nonce $VN"

mk() { # key nonce amount zeroForOne receiver
  cast mktx "$ROUTER" "$SIG" "$3" 0 "$4" "$POOLKEY" 0x "$5" "$DEADLINE" \
    --private-key "$1" --nonce "$2" --rpc-url "$RPC" --gas-limit 900000
}

RAW1=$(mk "$DEMO_ATTACKER_KEY" "$AN"       "$ATTACK_SIZE" true  "$DEMO_ATTACKER")  # front-run
RAW3=$(mk "$DEMO_ATTACKER_KEY" "$((AN+1))" "$ATTACK_SIZE" false "$DEMO_ATTACKER")  # exit
RAW2=$(mk "$DEMO_VICTIM_KEY"   "$VN"       "$VICTIM_SIZE" true  "$DEMO_VICTIM")    # victim

# Asymmetric stagger, and the asymmetry is the whole trick.
#
# The attacker's two legs use consecutive nonces from one account, which sequencers tend to pack
# adjacently — so an evenly spaced publish reliably produces front-run, exit, victim, with nobody
# in between. That is a round trip, not a sandwich, and the detector correctly refuses to call it
# one. Observed repeatedly before this was tuned.
#
# So the victim goes out almost immediately after the front-run, and the exit is held back long
# enough for the victim to be ordered ahead of it — while still landing inside the same ~1s block.
# Too short and the exit jumps the victim; too long and the exit slips into the next block and
# there is no sandwich either. Both failure modes are reported rather than retried silently.
VICTIM_DELAY=${VICTIM_DELAY:-0.05}
EXIT_DELAY=${EXIT_DELAY:-0.45}

echo "Publishing: front-run, +${VICTIM_DELAY}s victim, +${EXIT_DELAY}s exit..."
TMP=$(mktemp -d)
cast publish "$RAW1" --rpc-url "$RPC" --async > "$TMP/1" 2>&1 &
sleep "$VICTIM_DELAY"
cast publish "$RAW2" --rpc-url "$RPC" --async > "$TMP/2" 2>&1 &
sleep "$EXIT_DELAY"
cast publish "$RAW3" --rpc-url "$RPC" --async > "$TMP/3" 2>&1 &
wait

TX1=$(tr -d '[:space:]' < "$TMP/1")
TX2=$(tr -d '[:space:]' < "$TMP/2")
TX3=$(tr -d '[:space:]' < "$TMP/3")
rm -rf "$TMP"

echo "  front-run $TX1"
echo "  victim    $TX2"
echo "  exit      $TX3"
echo "Waiting for receipts..."
for tx in "$TX1" "$TX2" "$TX3"; do
  cast receipt "$tx" --rpc-url "$RPC" --confirmations 1 >/dev/null 2>&1 || true
done

TOPIC=$(cast keccak "ToxicFlowDetected(bytes32,address,uint8,uint256,uint256,uint24)")

# bash 3.2 (macOS default) has no associative arrays; plain globals it is.
BLK_FRONT=0; BLK_VICTIM=0; BLK_EXIT=0

report() {
  local label=$1 tx=$2 var=$3 json blk data
  json=$(cast receipt "$tx" --rpc-url "$RPC" --json)
  blk=$(( $(echo "$json" | jq -r '.blockNumber') ))
  eval "$var=$blk"
  data=$(echo "$json" | jq -r --arg t "$TOPIC" '.logs[] | select(.topics[0]==$t) | .data' | head -1)

  printf '  %-20s block %s  ' "$label" "$blk"
  if [ -z "$data" ]; then
    printf 'NOT FLAGGED\n'
  else
    local d=${data#0x}
    printf 'signal=%s penalty=%s  (observed %s vs threshold %s)\n' \
      "$(cast to-dec 0x${d:0:64})"   "$(cast to-dec 0x${d:192:64})" \
      "$(cast to-dec 0x${d:64:64})"  "$(cast to-dec 0x${d:128:64})"
  fi
}

echo
echo "=== result ==="
report "front-run" "$TX1" BLK_FRONT
report "victim"    "$TX2" BLK_VICTIM
report "exit"      "$TX3" BLK_EXIT

echo
echo "  signal: 0=None  1=SandwichExit  2=BlockReversal  3=SizeAnomaly"
echo "  penalty is hundredths of a bip on top of the 0.30% base fee (47000 = +4.70%)"
echo
if [ "$BLK_FRONT" = "$BLK_EXIT" ]; then
  echo "  ✓ attacker's legs shared block $BLK_FRONT — SandwichExit was reachable."
else
  echo "  ✗ legs split across blocks $BLK_FRONT and $BLK_EXIT — SandwichExit could not fire."
  echo "    Weaker detectors still responded. Re-run to try for co-location."
fi

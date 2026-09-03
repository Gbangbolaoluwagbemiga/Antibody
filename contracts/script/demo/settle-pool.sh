#!/usr/bin/env bash
# Feed pool A ordinary flow until its learned band sits back inside the Try-it slider's range.
#
# WHY THIS EXISTS
# Every sandwich run is a 2-token trade, roughly 1.8% of pool A's liquidity, well outside what that
# pool considers normal. The EWMA does what it is supposed to and widens the band to accommodate
# what it has just seen. After enough attacks the band climbs past 2.68% -- the largest swap the
# slider can express -- and the "drag it until the verdict flips" demo stops being possible on that
# pool. Nothing is broken; the pool has simply learned that large trades are normal here, because
# lately they have been.
#
# This is not a reset. There is no reset -- no owner, no setter, no privileged call. It is ordinary
# small flow, and the baseline comes back down the same way it went up: one swap at a time.
#
#   bash contracts/script/demo/settle-pool.sh          # default target 1.2%
#   bash contracts/script/demo/settle-pool.sh 0.8      # aim lower
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a

TARGET="${1:-1.2}"
RPC="${UNICHAIN_SEPOLIA_RPC_URL:-https://sepolia.unichain.org}"
ROUTER=0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba
SIG='swapExactTokensForTokens(uint256,uint256,bool,(address,address,uint24,int24,address),bytes,address,uint256)'
POOL_A=$(cast keccak "$(cast abi-encode 'f((address,address,uint24,int24,address))' "($TOKEN0,$TOKEN1,8388608,60,$HOOK_ADDRESS)")")
ME=$(cast wallet address --private-key "$PRIVATE_KEY")

now() { cast call "$HOOK_ADDRESS" 'currentThreshold(bytes32)(uint256)' "$POOL_A" --rpc-url "$RPC" | cut -d' ' -f1; }
pct() { python3 -c "print(f'{$1/1e16:.4f}')"; }

echo "  pool A now: $(pct "$(now)")%   target: ${TARGET}%"

for round in 1 2 3 4 5 6; do
  CUR=$(pct "$(now)")
  if python3 -c "import sys; sys.exit(0 if $CUR <= $TARGET else 1)"; then
    echo "  settled at ${CUR}% after $((round-1)) rounds"; exit 0
  fi
  echo "  round $round: ${CUR}% -> sending 20 swaps of 0.1 token0"
  N=$(cast nonce "$ME" --rpc-url "$RPC")
  DL=$(( $(date +%s) + 7200 ))
  for i in $(seq 0 19); do
    D=$([ $((i % 2)) -eq 0 ] && echo true || echo false)
    cast send "$ROUTER" "$SIG" 100000000000000000 0 "$D" \
      "($TOKEN0,$TOKEN1,8388608,60,$HOOK_ADDRESS)" 0x "$ME" "$DL" \
      --private-key "$PRIVATE_KEY" --rpc-url "$RPC" --nonce $((N+i)) --async > /dev/null 2>&1
  done
  sleep 45
done

echo "  stopped after 6 rounds at $(pct "$(now)")% — run it again if you need it lower"

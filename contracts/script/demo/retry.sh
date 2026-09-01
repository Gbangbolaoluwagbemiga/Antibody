#!/usr/bin/env bash
# forge script against a public testnet RPC fails intermittently with a bare
# "Failed to deploy script:" and no detail. It is transient, not a code fault, so every
# broadcast in the e2e sequence goes through here rather than being babysat by hand.
set -uo pipefail
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a
SCRIPT=$1; shift
for i in 1 2 3 4 5; do
  OUT=$(env "$@" forge script "$SCRIPT" --rpc-url "${UNICHAIN_SEPOLIA_RPC_URL:-https://sepolia.unichain.org}" \
        --private-key "$PRIVATE_KEY" --broadcast --slow 2>&1)
  if echo "$OUT" | grep -q "ONCHAIN EXECUTION COMPLETE"; then
    echo "  ok (attempt $i)"; exit 0
  fi
  echo "  attempt $i failed: $(echo "$OUT" | grep -E '^Error' | head -1)"
  sleep 20
done
echo "  GAVE UP after 5 attempts"; exit 1

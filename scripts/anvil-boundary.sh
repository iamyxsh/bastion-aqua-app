#!/usr/bin/env bash
# Milestone 1, increment 3 — boundary case. Run AFTER scripts/anvil-smoke.sh.
#
# Alice docks the strategy, then Bob replays the byte-identical calldata of the swap
# that just succeeded. Same input, same funding, different Aqua state -> it must revert.
# This is a REAL transaction that reverts on chain, not a simulation.
#
# Usage:  make boundary
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/contracts"
RPC="${RPC:-http://127.0.0.1:8545}"

# anvil test-mnemonic accounts 0 / 1 / 2 — public keys, local chain only
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ALICE_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BOB_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

B="broadcast/SmokeSwapLocal.s.sol/31337/run-latest.json"
[ -f "$B" ] || { echo "run scripts/anvil-smoke.sh first"; exit 1; }

# --- derive every address and hash from the recorded run, nothing hardcoded ---
read -r SHIP_TX SWAP_TX TAKER_APP FWETH FUSDC < <(python3 - "$B" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
tx=d['transactions']
fn=lambda p:[x for x in tx if (x.get('function') or '').startswith(p)]
mints=fn('mint(')
print(fn('ship(')[0]['hash'], fn('swap(')[0]['hash'],
      fn('swap(')[0]['contractAddress'], mints[0]['contractAddress'], mints[1]['contractAddress'])
PY
)

# Shipped(address maker, address app, bytes32 strategyHash, bytes strategy) — all
# non-indexed, so strategyHash is the third 32-byte word of the log data.
ORDER_HASH=$(cast receipt "$SHIP_TX" --rpc-url "$RPC" --json | python3 -c "
import sys,json
topic=json.load(sys.stdin)['logs'][0]['data'][2:]
print('0x'+topic[128:192])")

AQUA=$(cast call "$TAKER_APP" 'AQUA()(address)' --rpc-url "$RPC")
SWAPVM=$(cast call "$TAKER_APP" 'SWAPVM()(address)' --rpc-url "$RPC")
CALLDATA=$(cast tx "$SWAP_TX" input --rpc-url "$RPC")

# tokenA < tokenB by address, matching how the strategy was shipped.
# Lowercase via tr, not ${v,,} -- macOS ships bash 3.2, where ${v,,} is a syntax error.
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
if [ "$(lc "$FWETH")" \< "$(lc "$FUSDC")" ]; then
  TA=$FWETH; TB=$FUSDC
else
  TA=$FUSDC; TB=$FWETH
fi

echo "    Aqua=$AQUA  SwapVM=$SWAPVM  MockTaker=$TAKER_APP"
echo "    strategyHash=$ORDER_HASH"
echo
echo "==> before dock: aqua.safeBalances(fWETH, fUSDC)"
cast call "$AQUA" 'safeBalances(address,address,bytes32,address,address)(uint256,uint256)' \
  "$ALICE" "$SWAPVM" "$ORDER_HASH" "$FWETH" "$FUSDC" --rpc-url "$RPC" | sed 's/^/    /'

echo "==> re-fund Bob, so a failure cannot be blamed on his balance"
cast send "$FUSDC" 'mint(address,uint256)' "$TAKER_APP" 1000000000 \
  --rpc-url "$RPC" --private-key "$DEPLOYER_PK" --json \
  | python3 -c "import sys,json;print('    mint tx  ',json.load(sys.stdin)['transactionHash'])"

echo "==> Alice docks the strategy"
cast send "$AQUA" 'dock(address,bytes32,address[])' "$SWAPVM" "$ORDER_HASH" "[$TA,$TB]" \
  --rpc-url "$RPC" --private-key "$ALICE_PK" --json \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('    dock tx  ',d['transactionHash'],' status',d['status'])"

echo "==> Bob replays byte-identical swap calldata (must revert)"
set +e
OUT=$(cast send "$TAKER_APP" "$CALLDATA" --rpc-url "$RPC" --private-key "$BOB_PK" \
        --gas-limit 800000 --json 2>&1)
set -e
python3 -c "
import sys,json
raw='''$OUT'''
try:
    d=json.loads(raw); st=d.get('status')
    print('    replay tx',d['transactionHash'],' status',st)
    print('    RESULT:','REVERTED as expected' if st in ('0x0',0) else 'UNEXPECTEDLY SUCCEEDED -- investigate')
except Exception:
    print('    replay rejected before inclusion:'); print('   ',raw.strip()[:300])
"

echo "==> after dock: safeBalances must revert"
set +e
ERR=$(cast call "$AQUA" 'safeBalances(address,address,bytes32,address,address)(uint256,uint256)' \
        "$ALICE" "$SWAPVM" "$ORDER_HASH" "$FWETH" "$FUSDC" --rpc-url "$RPC" 2>&1)
set -e
SEL=$(printf '%s' "$ERR" | grep -o '0xb63386a6' | head -1)
if [ -n "$SEL" ]; then
  echo "    reverted with $SEL = SafeBalancesForTokenNotInActiveStrategy(maker,app,strategyHash,token)"
else
  echo "    UNEXPECTED: $ERR" | head -2
fi

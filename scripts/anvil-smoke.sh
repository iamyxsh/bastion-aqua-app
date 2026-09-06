#!/usr/bin/env bash
# Milestone 1, increment 3 — local anvil smoke test.
#
# Deploys the fixture world with `forge create`, then runs SmokeSwapLocal.s.sol for the
# calls. Deploys are NOT done inside the forge script: forge 1.0.0-stable aborts with
# "Failed to decode constructor arguments" on AquaSwapVMRouter, which kills the whole
# broadcast. See MILESTONES entry 2.
#
# Everything below is a LOCAL FIXTURE on chain 31337. The keys are anvil's published
# test-mnemonic keys: public by design, worthless off a local chain, never reused.
#
# Usage:  make anvil     (in one terminal)
#         make smoke     (in another)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/contracts"

RPC="${RPC:-http://127.0.0.1:8545}"
# anvil account 0 / 1 / 2 from the "test test ... junk" mnemonic
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
TAKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
ZERO=0x0000000000000000000000000000000000000000

cast chain-id --rpc-url "$RPC" > /dev/null 2>&1 || {
  echo "No chain at $RPC. Start one first:  make anvil"; exit 1; }

create() { # path:Name [constructor args...]
  local id="$1"; shift
  local out
  if [ "$#" -gt 0 ]; then
    out=$(forge create "$id" --rpc-url "$RPC" --private-key "$DEPLOYER_PK" \
            --broadcast --json --constructor-args "$@")
  else
    out=$(forge create "$id" --rpc-url "$RPC" --private-key "$DEPLOYER_PK" \
            --broadcast --json)
  fi
  python3 -c "import sys,json;d=json.load(sys.stdin);print(d['deployedTo'],d['transactionHash'])" <<< "$out"
}

echo "==> deploying local fixtures to $RPC"
read -r AQUA      AQUA_TX      < <(create node_modules/@1inch/aqua/src/Aqua.sol:Aqua)
read -r SWAPVM    SWAPVM_TX    < <(create src/routers/AquaSwapVMRouter.sol:AquaSwapVMRouter \
                                     "$AQUA" "$ZERO" "$DEPLOYER" "SwapVM" "1.0.0")
read -r FWETH     FWETH_TX     < <(create test/mocks/TokenMockDecimals.sol:TokenMockDecimals \
                                     "Local fixture WETH" "fWETH" 18)
read -r FUSDC     FUSDC_TX     < <(create test/mocks/TokenMockDecimals.sol:TokenMockDecimals \
                                     "Local fixture USDC" "fUSDC" 6)
read -r TAKER_APP TAKER_APP_TX < <(create test/mocks/MockTaker.sol:MockTaker \
                                     "$AQUA" "$SWAPVM" "$TAKER")

printf '  %-18s %s  %s\n' \
  "Aqua"             "$AQUA"      "$AQUA_TX" \
  "AquaSwapVMRouter" "$SWAPVM"    "$SWAPVM_TX" \
  "fWETH (18dp)"     "$FWETH"     "$FWETH_TX" \
  "fUSDC (6dp)"      "$FUSDC"     "$FUSDC_TX" \
  "MockTaker"        "$TAKER_APP" "$TAKER_APP_TX"

echo
echo "==> running SmokeSwapLocal"
AQUA="$AQUA" SWAPVM="$SWAPVM" FWETH="$FWETH" FUSDC="$FUSDC" TAKER_APP="$TAKER_APP" \
  forge script script/bastion/SmokeSwapLocal.s.sol:SmokeSwapLocal \
    --rpc-url "$RPC" --broadcast

echo
echo "==> broadcast receipts: contracts/broadcast/SmokeSwapLocal.s.sol/31337/run-latest.json"

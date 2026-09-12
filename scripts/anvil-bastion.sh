#!/usr/bin/env bash
# Milestone 3, increment 2 — the Bastion desk on a local anvil chain.
#
# One fill on book A changes what book B quotes, with real Aqua settlement and no
# transaction on B. Deploys the fixture world with `forge create`, then runs
# BastionSmokeLocal.s.sol for the calls.
#
# TWO LIBRARIES ARE DEPLOYED AND LINKED FIRST. `BastionAquaSwapVMRouter` does not fit in
# EIP-170's 24,576 bytes with `PMMMath` and the maker administration inlined (26,842 B
# measured — UPSTREAM.md, "Gate D1"). Both are `external` libraries, so they are reached by
# DELEGATECALL and still operate on the router's own storage.
#
# Deploys are NOT done inside the forge script: forge 1.0.0-stable aborts with
# "Failed to decode constructor arguments" on this router family, which kills the whole
# broadcast silently. See UPSTREAM.md.
#
# Everything below is a LOCAL FIXTURE on chain 31337. `fWETH` and `fUSDC` are mintable mocks,
# not real WETH or USDC. The keys are anvil's published test-mnemonic keys: public by design,
# worthless off a local chain, never reused anywhere.
#
# Usage:  make anvil    (in one terminal)
#         make bastion  (in another)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/contracts"

RPC="${RPC:-http://127.0.0.1:8545}"
# anvil accounts 0 / 1 / 2 / 3 from the "test test ... junk" mnemonic
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
TAKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
ZERO=0x0000000000000000000000000000000000000000

cast chain-id --rpc-url "$RPC" > /dev/null 2>&1 || {
  echo "No chain at $RPC. Start one first:  make anvil"; exit 1; }

LIBS=()

create() { # path:Name [constructor args...]
  local id="$1"; shift
  local args=(forge create "$id" --rpc-url "$RPC" --private-key "$DEPLOYER_PK" --broadcast --json)
  for l in "${LIBS[@]:-}"; do [ -n "$l" ] && args+=(--libraries "$l"); done
  if [ "$#" -gt 0 ]; then args+=(--constructor-args "$@"); fi
  local out; out=$("${args[@]}")
  python3 -c "import sys,json;d=json.load(sys.stdin);print(d['deployedTo'],d['transactionHash'])" <<< "$out"
}

echo "==> deploying linked libraries (gate D1: the router does not fit without them)"
read -r PMMMATH   PMMMATH_TX   < <(create src/bastion/pmm/PMMMath.sol:PMMMath)
LIBS+=("src/bastion/pmm/PMMMath.sol:PMMMath:$PMMMATH")
read -r DESKADMIN DESKADMIN_TX < <(create src/bastion/desk/DeskAdmin.sol:DeskAdmin)
LIBS+=("src/bastion/desk/DeskAdmin.sol:DeskAdmin:$DESKADMIN")

printf '  %-18s %s  %s\n' \
  "PMMMath"   "$PMMMATH"   "$PMMMATH_TX" \
  "DeskAdmin" "$DESKADMIN" "$DESKADMIN_TX"

echo
echo "==> deploying the fixture world to $RPC"
read -r AQUA      AQUA_TX      < <(create node_modules/@1inch/aqua/src/Aqua.sol:Aqua)
read -r DESK      DESK_TX      < <(create src/bastion/routers/BastionAquaSwapVMRouter.sol:BastionAquaSwapVMRouter \
                                     "$AQUA" "$ZERO" "$DEPLOYER" "Bastion" "1")
read -r FWETH     FWETH_TX     < <(create test/mocks/TokenMockDecimals.sol:TokenMockDecimals \
                                     "Local fixture WETH" "fWETH" 18)
read -r FUSDC     FUSDC_TX     < <(create test/mocks/TokenMockDecimals.sol:TokenMockDecimals \
                                     "Local fixture USDC" "fUSDC" 6)
read -r TAKER_APP TAKER_APP_TX < <(create test/mocks/MockTaker.sol:MockTaker \
                                     "$AQUA" "$DESK" "$TAKER")

printf '  %-26s %s  %s\n' \
  "Aqua"                      "$AQUA"      "$AQUA_TX" \
  "BastionAquaSwapVMRouter"   "$DESK"      "$DESK_TX" \
  "fWETH (18dp) LOCAL MOCK"   "$FWETH"     "$FWETH_TX" \
  "fUSDC (6dp)  LOCAL MOCK"   "$FUSDC"     "$FUSDC_TX" \
  "MockTaker"                 "$TAKER_APP" "$TAKER_APP_TX"

echo
echo "==> deployed router runtime size on chain"
SIZE=$(cast codesize "$DESK" --rpc-url "$RPC")
echo "  $SIZE bytes (EIP-170 limit 24576)"
[ "$SIZE" -le 24576 ] || { echo "  ROUTER EXCEEDS EIP-170"; exit 1; }

echo
echo "==> running BastionSmokeLocal"
AQUA="$AQUA" DESK="$DESK" FWETH="$FWETH" FUSDC="$FUSDC" TAKER_APP="$TAKER_APP" \
  forge script script/bastion/BastionSmokeLocal.s.sol:BastionSmokeLocal \
    --rpc-url "$RPC" --broadcast \
    --libraries "src/bastion/pmm/PMMMath.sol:PMMMath:$PMMMATH" \
    --libraries "src/bastion/desk/DeskAdmin.sol:DeskAdmin:$DESKADMIN"

echo
echo "==> broadcast receipts: contracts/broadcast/BastionSmokeLocal.s.sol/31337/run-latest.json"

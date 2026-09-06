#!/usr/bin/env bash
# Verify our vendored trees against their pinned upstream commits.
#
#   aqua/            must be IDENTICAL to the pin (spec §4: unmodified Aqua)
#   reference/dodo/  must be IDENTICAL to the pin (gate P1: independent oracle)
#   contracts/       may differ, but every differing file is printed so the
#                    "bounded fork" claim in UPSTREAM.md stays checkable.
#
# Usage: ./scripts/check-upstream.sh   (or: make check-upstream)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SWAPVM_PIN=9502fd44254fef12fa448c3059868505b4c9dfff
AQUA_PIN=9c5c42e5840e8741fba3597c48456c9510212b66
DODO_PIN=2f1bcdac7ef1beee7599a756e2eed26732c2536d

IGNORE=(-x '.git' -x '.github' -x 'node_modules' -x 'out' -x 'cache' -x 'artifacts'
        -x 'broadcast' -x 'deployments' -x '.DS_Store' -x 'package-lock.json' -x 'snapshots')

fetch() { # repo sha  -> prints extracted dir; fails loudly on a truncated download
  local tgz="$TMP/$(basename "$1")-$2.tgz"
  curl -sfL --retry 3 -o "$tgz" "https://github.com/$1/archive/$2.tar.gz"
  tar xzf "$tgz" -C "$TMP" || { echo "    FAIL - could not extract $1@$2" >&2; return 1; }
  echo "$TMP/$(basename "$1")-$2"
}

fetch_file() { # repo sha path -> prints local temp file
  local out="$TMP/$(echo "$1$3" | tr '/' '_')"
  curl -sfL --retry 3 -o "$out" "https://raw.githubusercontent.com/$1/$2/$3"
  echo "$out"
}

status=0

echo "==> Aqua  (must be identical)"
UP="$(fetch 1inch/aqua "$AQUA_PIN")"
if diff -r "${IGNORE[@]}" "$UP" "$ROOT/aqua" > "$TMP/aqua.diff" 2>&1; then
  echo "    OK — aqua/ matches ${AQUA_PIN:0:7}"
else
  echo "    FAIL — aqua/ has been modified. Spec §4 requires unmodified Aqua:"
  sed 's/^/      /' "$TMP/aqua.diff" | head -40
  status=1
fi

echo "==> DODO PMM reference  (must be identical)"
# Fetch the four files directly: contractV2's tarball carries large audit PDFs
# and truncates unreliably.
dodo_bad=0
for f in PMMPricing DODOMath DecimalMath SafeMath; do
  ref="$(fetch_file DODOEX/contractV2 "$DODO_PIN" "contracts/lib/$f.sol")"
  if [ ! -s "$ref" ]; then
    echo "    FAIL — could not download upstream $f.sol"; dodo_bad=1; status=1; continue
  fi
  if ! cmp -s "$ref" "$ROOT/reference/dodo/lib/$f.sol"; then
    echo "    FAIL — reference/dodo/lib/$f.sol differs from upstream"
    dodo_bad=1; status=1
  fi
done
[ "$dodo_bad" -eq 0 ] && echo "    OK — 4/4 files match ${DODO_PIN:0:7}"

echo "==> SwapVM  (bounded fork — differences are listed, not failed)"
UP="$(fetch 1inch/swap-vm "$SWAPVM_PIN")"
diff -rq "${IGNORE[@]}" "$UP" "$ROOT/contracts" > "$TMP/swapvm.diff" 2>&1 || true
if [ -s "$TMP/swapvm.diff" ]; then
  echo "    Fork surface vs ${SWAPVM_PIN:0:7}:"
  sed "s|$UP|<upstream>|g; s|$ROOT/contracts|<ours>|g; s/^/      /" "$TMP/swapvm.diff"
  echo "    -> every line above must appear in UPSTREAM.md \"Fork surface\"."
else
  echo "    OK — contracts/ is byte-identical to upstream (no fork surface yet)"
fi

echo
[ "$status" -eq 0 ] && echo "check-upstream: PASS" || echo "check-upstream: FAIL"
exit "$status"

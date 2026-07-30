#!/usr/bin/env bash
#
# Storage-layout guard for the delegatecall modules.
#
# `B4Vault` reaches `B4VaultOps` and `B4VaultRecovery` by `delegatecall`, so all three execute
# against ONE storage. Their layouts are identical today only because each inherits
# `B4VaultStorage` and declares no state of its own — a fact nothing enforced until this script.
# Add a variable to a module instead of to the shared base, or reorder the base, and the modules
# start reading different slots than the vault writes: owner, the accounting ledgers or the
# in-flight intent silently alias. Nothing reverts, and the unit tests keep passing, because at
# runtime every call already shares the vault's storage — the divergence is a COMPILE-TIME
# property that only a layout comparison can see.
#
# The immutability of the module addresses (RefactorGuards) removes the upgrade attack; it does
# not remove this one, which lands at deployment of a fresh implementation.
#
# Exit 0 when the three layouts agree, 1 with a diff when they do not.
set -euo pipefail

cd "$(dirname "$0")/.."

MODULES=(B4VaultOps B4VaultRecovery)
REFERENCE=B4Vault

layout() {
  # `forge inspect` reads the layout out of the build artifact and reports it missing when the
  # cached artifact predates the request. A clean rebuild is the documented remedy; do it once,
  # rather than reporting a cache artefact as layout drift.
  local contract=$1
  if ! forge inspect "src/core/${contract}.sol:${contract}" storageLayout --json 2>/dev/null; then
    forge clean >/dev/null
    forge build --skip test --skip script >/dev/null
    forge inspect "src/core/${contract}.sol:${contract}" storageLayout --json
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for c in "$REFERENCE" "${MODULES[@]}"; do
  # slot/offset/label/type is exactly the tuple that must not move. Two normalisations, both
  # necessary or the guard cries wolf and gets muted:
  #   * `astId` is a source position and moves with any unrelated edit above it;
  #   * a struct's TYPE carries its astId too (`t_struct(FeeRoute)7218_storage`), so adding a
  #     line to one file renumbers the type string in every contract that mentions the struct —
  #     which reports drift in modules that did not change. The struct's identity is its name and
  #     its member layout, not the number, so the number goes.
  layout "$c" | jq -S '
    [ .storage[]
      | { slot, offset, label,
          type: (.type | gsub("\\)[0-9]+_storage"; ")_storage")) }
    ]' >"$tmp/$c.json"
done

status=0
for m in "${MODULES[@]}"; do
  if diff -u "$tmp/$REFERENCE.json" "$tmp/$m.json" >"$tmp/$m.diff"; then
    echo "ok   $m layout matches $REFERENCE ($(jq 'length' "$tmp/$m.json") slots)"
  else
    echo "FAIL $m storage layout has drifted from $REFERENCE:"
    cat "$tmp/$m.diff"
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo
  echo "These contracts share one storage through delegatecall. A layout that differs means the"
  echo "modules read slots the vault does not write. Declare shared state in B4VaultStorage only,"
  echo "and append rather than reorder."
fi

exit "$status"

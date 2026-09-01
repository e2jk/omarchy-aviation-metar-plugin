#!/bin/bash
# Portable subset of `omarchy plugin validate` (see
# /usr/share/omarchy/bin/omarchy-plugin-validate on an Omarchy machine for
# the authoritative, stricter version) — just enough to catch a broken
# manifest.json without requiring Omarchy to be installed, so it can run in
# CI as well as the pre-push hook. When the real `omarchy` CLI is available
# (i.e. running on an actual Omarchy machine), the pre-push hook runs that
# too, as the stricter check.

set -euo pipefail

fail() {
  echo "validate-manifest: $*" >&2
  exit 1
}

MANIFEST="manifest.json"
[[ -f $MANIFEST ]] || fail "missing $MANIFEST"

command -v jq >/dev/null 2>&1 || fail "jq is required"

jq -e . "$MANIFEST" >/dev/null 2>&1 || fail "manifest.json is not valid JSON"

jq -e '.schemaVersion == 1' "$MANIFEST" >/dev/null 2>&1 \
  || fail "unsupported or missing schemaVersion (expected 1)"

for field in id name version kinds entryPoints; do
  jq -e --arg f "$field" 'has($f)' "$MANIFEST" >/dev/null 2>&1 \
    || fail "manifest missing required field '$field'"
done

ID=$(jq -r '.id // ""' "$MANIFEST")
[[ -n $ID ]] || fail "manifest 'id' is empty"
[[ $ID != omarchy.* ]] || fail "plugin id '$ID' uses the reserved omarchy.* namespace"

jq -e '(.kinds | type) == "array" and (.kinds | length) > 0' "$MANIFEST" >/dev/null 2>&1 \
  || fail "'kinds' must be a non-empty array"

# Every entryPoints value must be a relative path that actually exists.
while IFS= read -r ep_json; do
  [[ -n $ep_json ]] || continue
  ep=$(jq -r '.' <<< "$ep_json")
  [[ -n $ep ]] || fail "entry point path is empty"
  [[ $ep != /* ]] || fail "entry point must be a relative path: '$ep'"
  [[ $ep != *".."* ]] || fail "entry point may not contain '..': '$ep'"
  [[ -f "$ep" ]] || fail "entry point file not found: '$ep'"
done < <(jq -c '.entryPoints | to_entries[] | .value' "$MANIFEST")

echo "manifest.json: schema OK, id '$ID', entry points present"

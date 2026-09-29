#!/bin/bash
# Runs qmllint on this plugin's QML files, treating every semantic/type
# warning category as non-fatal ("info") — actual syntax errors (a
# separate, non-leveled mechanism; only -s/--silent affects them, which
# this deliberately never passes) stay fully fatal.
#
# Why every category, not just a known-noisy subset: Quickshell's qs.*
# namespace and base types (BarWidget, Panel, ...) aren't resolvable
# without Quickshell's own build, so essentially any type/property-aware
# check can misfire on this codebase — not a fixed, enumerable set. Trying
# to hardcode "the noisy ones" already broke pre-push/CI twice:
#   1. The exact flag set differs by Qt version (CI's Ubuntu 24.04 package
#      is Qt 6.4.2, well behind a typical dev machine's 6.11+) — some
#      flags this repo used didn't exist yet in 6.4.2 at all.
#   2. Worse: some checks aren't even *missing* in 6.4.2, they're the same
#      check under a different flag name — "missing-property" is called
#      "property" there, "unresolved-type" is "type", the same for
#      "signal-handler-parameters" vs "signal" — so detecting "does this
#      exact flag name exist" and skipping it when absent isn't enough;
#      the check still ran under its old name, at whatever default level
#      that Qt version uses (verified: 6.4.2 has no separate error/warning
#      distinction with a max-warnings threshold like 6.11+ does — its
#      "warning" level fails immediately on any occurrence).
# Extracting every "--<category> <level>" option qmllint itself reports via
# --help, and forcing all of them to "info", is what actually survives that
# kind of version drift: it doesn't matter what a category is named or
# whether it exists in a given build, because every category actually
# offered gets covered, automatically.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# The fixed Qt6 path is checked first, not last: a `qmllint` resolved via
# PATH is not necessarily the Qt6 one this script's whole category-flag
# extraction is written against — confirmed live on a machine that also has
# qt5-declarative installed, whose own (PATH-first) qmllint 1.0 has none of
# the `--<category> <level>` options at all, so the extraction below found
# zero categories, ran with zero flags, and failed opaquely with no output.
# Same "a fixed, known path beats an ambiguous PATH lookup" reasoning
# Model.js applies to every executable this plugin itself shells out to.
if [[ -x /usr/lib/qt6/bin/qmllint ]]; then
  qmllint_bin=/usr/lib/qt6/bin/qmllint
elif command -v qmllint >/dev/null 2>&1; then
  qmllint_bin=qmllint
else
  echo "run-qmllint: qmllint not found, skipping QML lint" >&2
  exit 0
fi

help_output=$("$qmllint_bin" --help 2>&1 || true)
mapfile -t categories < <(grep -oE '^[[:space:]]*(-[^,[:space:]],[[:space:]]*)?--[a-zA-Z-]+ <level>' <<< "$help_output" \
  | grep -oE -- '--[a-zA-Z-]+')

flags=()
for category in "${categories[@]}"; do
  flags+=("$category" info)
done

"$qmllint_bin" "${flags[@]}" BarWidget.qml Panel.qml

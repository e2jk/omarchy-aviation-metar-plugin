#!/bin/bash
# Runs qmllint on this plugin's QML files, suppressing exactly the warning
# categories that are false positives here: Quickshell's qs.* namespace and
# base types (BarWidget, Panel, ...) aren't resolvable without Quickshell's
# own build, not something a -I path fixes (see the README's Development
# section for what was verified about each category).
#
# Which of those category flags actually exist varies by Qt version — CI's
# Ubuntu-packaged qmllint (Qt 6.4.2 on 24.04) is noticeably older than a
# typical Omarchy machine's (Qt 6.11+), and doesn't recognize all of them.
# Detecting support via --help rather than hardcoding a fixed list is the
# whole point of this being one shared script instead of the same flags
# copy-pasted into the pre-push hook and the CI workflow: that duplication
# is exactly how this broke the first time (only ever tested against one
# Qt version). A category this qmllint doesn't know about isn't something
# it can generate warnings for in the first place, so leaving it off the
# command line rather than erroring is the correct behavior, not a gap.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if command -v qmllint >/dev/null 2>&1; then
  qmllint_bin=qmllint
elif [[ -x /usr/lib/qt6/bin/qmllint ]]; then
  qmllint_bin=/usr/lib/qt6/bin/qmllint
else
  echo "run-qmllint: qmllint not found, skipping QML lint" >&2
  exit 0
fi

help_output=$("$qmllint_bin" --help 2>&1 || true)

categories=(import unresolved-type missing-property inheritance-cycle unqualified signal-handler-parameters)
flags=()
for category in "${categories[@]}"; do
  if grep -q -- "--$category " <<< "$help_output"; then
    flags+=(--"$category" disable)
  fi
done

"$qmllint_bin" "${flags[@]}" BarWidget.qml Panel.qml

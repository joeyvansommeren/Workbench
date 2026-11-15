#!/usr/bin/env bash
#
# Toolbar guard for the new shell. Fails when code in the new-shell folders
# uses a SwiftUI toolbar: `.toolbar(…)` / `.toolbar { … }`, `ToolbarItem…` or
# `.searchable(…)`. Any of them makes SwiftUI give the window an `NSToolbar`,
# and with a toolbar AppKit turns every click in the title row into a window
# drag (release blocker, 2026-11-14; Shell/README.md, "Title row clicks").
# `ShellTitleBarHitTests` catches it at runtime; this catches it in CI.
#
# Usage: scripts/check-shell.sh [files…]   (also run by scripts/test.sh)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/app/modules/AgentHubCore/Sources/AgentHub"

# Code that can end up in the new shell's window.
TARGETS=(
  "$SRC/Shell"
  "$SRC/Reviews"
  "$SRC/Sprint"
  "$SRC/Design"
  "$SRC/Jira/SprintDestinationView.swift"
  "$SRC/Linear/LinearSprintDestination.swift"
)

# Legacy (flag-off) views in those folders. They never load in the shell.
ALLOWED=(
  "$SRC/Reviews/GitHubReviewsView.swift"
)

FILES=()
if [ "$#" -gt 0 ]; then
  # Explicit files (used to check the guard itself).
  FILES=("$@")
else
  while IFS= read -r file; do
    allowed=0
    for legacy in "${ALLOWED[@]}"; do
      [ "$file" = "$legacy" ] && allowed=1
    done
    [ "$allowed" -eq 0 ] && FILES+=("$file")
  done < <(find "${TARGETS[@]}" -name '*.swift' 2>/dev/null | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "check-shell: no Swift files found under $SRC" >&2
  exit 2
fi

# Comment lines are skipped, so the docs that explain the rule do not trip it.
perl -ne '
  next if /^\s*\/\//;
  if (/\.toolbar\s*[({]|\bToolbarItem\w*\b|\.searchable\s*\(/) {
    print "$ARGV:$.: SwiftUI toolbar API (creates an NSToolbar; title row clicks break)\n";
    $main::found++;
  }
  close ARGV if eof;  # reset $. per file
  END { exit($main::found ? 1 : 0) }
' "${FILES[@]}"
status=$?

if [ "$status" -eq 0 ]; then
  echo "✓ shell guard: no SwiftUI toolbar in new-shell code (${#FILES[@]} files)"
else
  echo "✗ shell guard failed: the shell window must have no NSToolbar (Shell/README.md, \"Title row clicks\")" >&2
fi
exit "$status"

#!/usr/bin/env bash
# Native test windows must use the shared background presentation policy.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=()
if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  # Scan repository-owned tests, including new files before they are staged.
  # Generated dependency checkouts can contain unrelated APIs such as SQL order().
  # NUL separators preserve paths containing whitespace or newlines.
  while IFS= read -r -d '' file; do
    case "$file" in
      app/modules/AgentHubCore/Tests/AgentHubTests/BackgroundTestWindow.swift) continue ;;
      app/modules/*/Tests/*.swift)
        [ -f "$ROOT/$file" ] && FILES+=("$ROOT/$file")
        ;;
    esac
  done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- app/modules)
fi
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "check-test-windows: no test files found" >&2
  exit 2
fi
perl -ne '
  next if /^\s*\/\//;
  if (/\.(?:makeKeyAndOrderFront|orderFrontRegardless|orderFront|orderBack|order)\s*\(|\.activate\s*\(\s*ignoringOtherApps:/) {
    print "$ARGV:$.: use BackgroundTestWindow.presentForTesting(), not direct window presentation or app activation\n";
    $main::found++;
  }
  close ARGV if eof;
  END { exit($main::found ? 1 : 0) }
' "${FILES[@]}"
status=$?
if [ "$status" -eq 0 ]; then
  echo "✓ test window guard: no direct foreground presentation"
fi
exit "$status"

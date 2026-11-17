#!/usr/bin/env bash
# Native test windows must use the shared background presentation policy.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=()
if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  while IFS= read -r file; do
    FILES+=("$file")
  done < <(find "$ROOT/app/modules" -path '*/Tests/*' -name '*.swift' \
    ! -path '*/AgentHubTests/BackgroundTestWindow.swift' | sort)
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

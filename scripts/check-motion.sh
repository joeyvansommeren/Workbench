#!/usr/bin/env bash
#
# Motion guard for the new shell (motion plan item 17). Fails when code in the
# new-shell folders scales on press or hover, or uses a bouncy spring.
# Joey's rule: hover and press change colour only; every spring is critically
# damped (dampingFraction 1). Press scales came back once from the prototype;
# this check keeps them out.
#
# Usage: scripts/check-motion.sh   (also run by scripts/test.sh)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/app/modules/AgentHubCore/Sources/AgentHub"

# New-shell code, plus the two legacy button styles the new Jira and Linear
# detail panels still use.
TARGETS=(
  "$SRC/Shell"
  "$SRC/Design/Components"
  "$SRC/Design/Motion"
  "$SRC/Design/Tokens"
  "$SRC/Reviews"
  "$SRC/Sprint"
  "$SRC/Jira"
  "$SRC/Linear"
  "$SRC/Design/WorkspaceChrome.swift"
  "$SRC/Design/AgentHubButtonStyle.swift"
)

FILES=()
if [ "$#" -gt 0 ]; then
  # Explicit files (used to check the guard itself against old code).
  FILES=("$@")
else
  while IFS= read -r file; do
    FILES+=("$file")
  done < <(find "${TARGETS[@]}" -name '*.swift' 2>/dev/null | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "check-motion: no Swift files found under $SRC" >&2
  exit 2
fi

# Perl reads each file whole, so a `scaleEffect(` that spans lines is caught.
# Rules:
#   1. scaleEffect whose argument reads a press or hover state.
#   2. dampingFraction below 1 (0.x), which overshoots.
#   3. .bouncy / .snappy / .interpolatingSpring / argument-less .spring().
perl -0777 -ne '
  my $file = $ARGV;
  my @rules = (
    [qr/scaleEffect\(\s*[^()]*?(?:\([^()]*\)[^()]*?)*?\b(?:isPressed|isHover\w*|hovering|pressed)\b/s,
      "scale on press or hover (colour only, Joey rule)"],
    [qr/dampingFraction:\s*0?\.\d/, "dampingFraction below 1 (bounce)"],
    [qr/\.(?:bouncy|snappy|interpolatingSpring)\b/, "bouncy spring preset"],
    [qr/\.spring\(\s*\)/, "argument-less .spring() (bounces)"],
  );
  for my $rule (@rules) {
    my ($pattern, $why) = @$rule;
    while (/$pattern/g) {
      my $line = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
      print "$file:$line: $why\n";
      $main::found++;
    }
  }
  END { exit($main::found ? 1 : 0) }
' "${FILES[@]}"
status=$?

if [ "$status" -eq 0 ]; then
  echo "✓ motion guard: no press/hover scale, no bouncy springs (${#FILES[@]} files)"
else
  echo "✗ motion guard failed: hover and press change colour only; springs use dampingFraction 1" >&2
fi
exit "$status"

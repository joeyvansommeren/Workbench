#!/bin/zsh
# Update the installed Workbench.app to the latest main.
#
# Pulls main, builds a Debug app, quits Workbench, replaces
# /Applications/Workbench.app, and relaunches it.
#
#   make update          # pull main, build, install, relaunch
#   make install         # build and install the current checkout, no pull
#
# Workbench has no auto-update: merging a PR on GitHub does not change the
# installed app. Run this after merging.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

app_name="Workbench.app"
install_path="/Applications/$app_name"
derived_data="$repo_root/build/DerivedData"
built_app="$derived_data/Build/Products/Debug/$app_name"
log_file="$repo_root/build/update.log"
mkdir -p "$repo_root/build"

if [[ "${1:-}" != "--no-pull" ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" != "main" ]]; then
    echo "error: this checkout is on '$branch'. Run 'make update' from a checkout of main," >&2
    echo "       or 'make install' to install the current branch without pulling." >&2
    exit 1
  fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: uncommitted changes in $repo_root. Commit or stash them first." >&2
    exit 1
  fi
  echo "→ Pulling main"
  git pull --ff-only origin main
fi

for tool in pkg-config xcodebuild; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found. See WORKBENCH.md." >&2; exit 1; }
done
pkg-config --exists libgit2 || { echo "error: libgit2 missing. Run: brew install libgit2 pkgconf" >&2; exit 1; }

echo "→ Building $(git rev-parse --short HEAD) (log: build/update.log)"
if ! xcodebuild \
    -workspace app/AgentHub.xcodeproj/project.xcworkspace \
    -scheme AgentHub -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" -allowProvisioningUpdates \
    -skipPackagePluginValidation -skipMacroValidation \
    build >"$log_file" 2>&1; then
  grep -E 'error:' "$log_file" | sort -u | head -20 >&2 || true
  echo "error: build failed. The installed app was not changed. Full log: $log_file" >&2
  exit 1
fi

echo "→ Installing to $install_path"
if pgrep -xq Workbench; then
  osascript -e 'tell application "Workbench" to quit' >/dev/null 2>&1 || true
  # Give the app time to close its terminals before the bundle is replaced.
  for _ in {1..20}; do pgrep -xq Workbench || break; sleep 0.5; done
fi
rm -rf "$install_path"
ditto "$built_app" "$install_path"

echo "→ Launching"
open "$install_path"
echo "✓ Workbench updated to $(git rev-parse --short HEAD)"

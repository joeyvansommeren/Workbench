#!/usr/bin/env python3
"""Compile the real watcher and exercise lifecycle traps in a disposable child."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = root / "app/modules/AgentHubCore/Sources/AgentHub/Services/PendingSessionDirectoryWatcher.swift"
driver = root / "scripts/PendingSessionWatcherProbe.swift"

try:
    with tempfile.TemporaryDirectory(prefix="pending-watcher-guard-") as directory:
        binary = pathlib.Path(directory) / "watcher-probe"
        subprocess.run(
            ["xcrun", "swiftc", "-module-cache-path", str(pathlib.Path(directory) / "cache"),
             "-parse-as-library", str(source), str(driver), "-o", str(binary)],
            check=True, timeout=120,
        )
        subprocess.run([str(binary)], check=True, timeout=30)
except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
    print(f"Pending session watcher guard failed: {error}", file=sys.stderr)
    sys.exit(1)

#!/usr/bin/env python3
"""Exercise the real helper against disposable processes, including detached children.

Usage: python3 scripts/test-process-guard.py /path/to/agenthub
"""
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import time


def alive(pid):
    state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                           capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


def wait_gone(pid):
    deadline = time.monotonic() + 8
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    assert not alive(pid), f"Process {pid} survived cleanup"


if len(sys.argv) == 4 and sys.argv[1] == "--parent":
    helper, node = sys.argv[2:]
    guard = subprocess.Popen([helper, "process-guard", "--parent-pid", str(os.getpid())],
                             stdout=subprocess.PIPE, text=True)
    assert guard.stdout.readline().strip() == "ready"
    root = subprocess.Popen([node, "-e", """
const child = require('child_process').spawn(process.execPath,
  ['-e', 'setInterval(() => {}, 1000)'], { detached: true, stdio: 'ignore' });
console.log(child.pid);
setInterval(() => {}, 1000);
"""], stdout=subprocess.PIPE, text=True)
    child_pid = int(root.stdout.readline())
    second = subprocess.Popen([node, "-e", "setInterval(() => {}, 1000)"])
    print(json.dumps([guard.pid, root.pid, child_pid, second.pid]), flush=True)
    time.sleep(60)
else:
    node = shutil.which("node")
    assert node, "Node is required for this integration test"
    outsider = subprocess.Popen([node, "-e", "setInterval(() => {}, 1000)"])
    parent = subprocess.Popen([sys.executable, __file__, "--parent", sys.argv[1], node],
                              stdout=subprocess.PIPE, text=True)
    pids = []
    try:
        assert select.select([parent.stdout], [], [], 15)[0], "Test parent did not start"
        guard, root, child, second = pids = json.loads(parent.stdout.readline())
        print(f"Test PIDs: guard={guard}, root={root}, child={child}, second={second}, unrelated={outsider.pid}", flush=True)
        time.sleep(1.5)  # Let the guard observe both generations before reparenting.
        os.kill(root, signal.SIGTERM)
        wait_gone(child)
        assert alive(second), f"Other session {second} stopped; parent exit={parent.poll()}"
        assert alive(outsider.pid), "Cleanup touched the unrelated process"
        parent.kill()  # A force quit must not disable the independent guard.
        parent.wait()
        wait_gone(second)
        wait_gone(guard)
        assert alive(outsider.pid), "Cleanup touched a process outside AgentHub"
        print("PASS: session exit, detached child, force quit, guard exit, unrelated process preserved")
    finally:
        if parent.poll() is None:
            parent.kill()
        parent.wait()
        outsider.terminate()
        outsider.wait()
        # Only the disposable PIDs from this test; skip processes already reaped.
        for pid in pids:
            if alive(pid):
                os.kill(pid, signal.SIGKILL)

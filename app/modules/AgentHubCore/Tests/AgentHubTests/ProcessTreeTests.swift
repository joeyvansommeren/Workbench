import Darwin
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Process tree")
struct ProcessTreeTests {
  @Test("Does not kill a PID whose start time differs from the captured process")
  func preservesReusedPID() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer {
      child.terminate()
      child.waitUntilExit()
    }
    let current = try #require(ProcessTree.identity(for: child.processIdentifier))
    let stale = ProcessTree.Identity(pid: current.pid, startSeconds: current.startSeconds,
      startMicroseconds: current.startMicroseconds + 1)
    ProcessTree.killSurvivors([stale], root: current.pid)
    #expect(ProcessTree.identity(for: current.pid) == current)
    #expect(ProcessTree.sendTerminate(root: 0).isEmpty)
    #expect(ProcessTree.sendTerminate(root: -1).isEmpty)
  }

  @Test("Stops a child that runs in its own process group, like a Codex MCP server")
  func stopsChildInOwnProcessGroup() async throws {
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sh")
    parent.arguments = ["-c", "/usr/bin/perl -e 'setpgrp(0,0); sleep 30' & sleep 30"]
    try parent.run()
    let root = parent.processIdentifier
    defer {
      ProcessTree.killSurvivors(ProcessTree.sendTerminate(root: root), root: root)
      parent.waitUntilExit()
    }

    var tree: [pid_t] = []
    for _ in 0..<100 {
      try await Task.sleep(for: .milliseconds(20))
      tree = ProcessTree.pids(under: root)
      if tree.count >= 3, tree.dropFirst().contains(where: { getpgid($0) == $0 }) { break }
    }
    #expect(tree.count >= 3)
    let detached = try #require(tree.dropFirst().first { getpgid($0) == $0 })

    let sent = ProcessTree.sendTerminate(root: root)
    try await Task.sleep(for: .milliseconds(300))
    ProcessTree.killSurvivors(sent, root: root)
    try await Task.sleep(for: .milliseconds(100))

    #expect(kill(detached, 0) != 0)
    parent.waitUntilExit()
  }
}

import Darwin
import Testing
@testable import AgentHubCLIKit

@Suite("Node process guard")
struct NodeProcessGuardTests {
  let app = process(10, parent: 1, name: "AgentHub")

  @Test func normalParallelWorkloadFitsNewDefaults() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11)
    let nodes = (100..<200).map { process(Int32($0), parent: 10, bytes: 100 * 1_048_576) }
    let result = policy.update([app] + nodes)
    #expect(result.targets.isEmpty)
    #expect(result.reason.isEmpty)
  }

  @Test func defaultCountAndMemoryLimitsStillApply() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11)
    let nodes = (100..<357).map { process(Int32($0), parent: 10) }
    let count = policy.update([app] + nodes)
    #expect(count.targets.count == 1)
    #expect(count.reason.contains("257 Node processes (limit 256)"))
    let individual = policy.update([app, process(20, parent: 10, bytes: 4 * 1024 * 1_048_576 + 1)])
    #expect(individual.targets.count == 1)
    #expect(individual.reason.contains("one process uses"))
    let total = policy.update([app] + (100..<106).map { process(Int32($0), parent: 10, bytes: 3 * 1024 * 1_048_576) })
    #expect(total.targets.count == 1)
    #expect(total.reason.contains("18432 MiB combined (limit 16384 MiB)"))
  }

  @Test func onlyOwnDescendantsCountTowardLimits() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11, maximumCount: 1)
    let processes = [app, process(11, parent: 10, name: "agenthub"),
      process(12, parent: 11), process(20, parent: 10), process(21, parent: 20),
      process(30, parent: 1, bytes: 10_000_000_000)]
    let result = policy.update(processes)
    #expect(result.limited)
    #expect(result.targets.map(\.identity.pid) == [21])
    #expect(policy.owned.count == 2)
  }

  @Test func limitsIndividualAndAggregateFootprint() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11,
      maximumProcessBytes: 100, maximumTotalBytes: 150)
    let root = process(20, parent: 10, name: "codex")
    let result = policy.update([app, root, process(21, parent: 20, bytes: 101),
      process(22, parent: 20, bytes: 90), process(23, parent: 20, bytes: 80)])
    #expect(Set(result.targets.map(\.identity.pid)) == [21, 22])
  }

  @Test func exactLimitsDoNotStopProcesses() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11, maximumCount: 2,
      maximumProcessBytes: 100, maximumTotalBytes: 200)
    #expect(policy.update([app, process(20, parent: 10, bytes: 100),
      process(21, parent: 10, bytes: 100)]).targets.isEmpty)
  }

  @Test func cleansReparentedChildrenAfterSessionExit() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11)
    _ = policy.update([app, process(20, parent: 10, name: "codex"), process(21, parent: 20)])
    let result = policy.update([app, process(21, parent: 1)])
    #expect(result.targets.map(\.identity.pid) == [21])
    #expect(!result.limited)
  }

  @Test func forceQuitCleansAllKnownDescendantsButNotReusedPIDs() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11)
    _ = policy.update([app, process(20, parent: 10), process(21, parent: 20),
      process(22, parent: 20, name: "java")])
    let result = policy.update([process(20, parent: 1), process(21, parent: 1, started: 999),
      process(22, parent: 1, name: "java"), process(30, parent: 1)])
    #expect(Set(result.targets.map(\.identity.pid)) == [20, 22])
  }

  @Test func appPIDReuseDoesNotAdoptUnrelatedChildren() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11)
    _ = policy.update([app, process(20, parent: 10)])
    let result = policy.update([process(10, parent: 1, started: 999),
      process(20, parent: 1), process(30, parent: 10)])
    #expect(result.targets.map(\.identity.pid) == [20])
  }

  @Test func observesNewChildrenOfKnownProcessesDuringShutdown() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11)
    _ = policy.update([app, process(20, parent: 10)])
    let result = policy.update([process(20, parent: 1), process(21, parent: 20)])
    #expect(Set(result.targets.map(\.identity.pid)) == [20, 21])
  }

  @Test func includesNonNodeDescendantsOfStoppedNode() {
    var policy = NodeProcessPolicy(app: app.identity, guardian: 11, maximumProcessBytes: 100)
    let result = policy.update([process(22, parent: 21, name: "java"),
      process(21, parent: 20, name: "sh"), process(20, parent: 10, bytes: 101), app])
    #expect(Set(result.targets.map(\.identity.pid)) == [20, 21, 22])
  }

  @Test func nativeSnapshotContainsCurrentProcess() throws {
    let own = try #require(NodeProcessGuard.read(getpid()))
    #expect(own.identity.started > 0)
    #expect(own.bytes > 0)
    #expect(NodeProcessGuard.snapshot().contains { $0.identity == own.identity })
  }
}

private func process(_ pid: Int32, parent: Int32, name: String = "node",
  bytes: UInt64 = 1, started: UInt64? = nil) -> GuardProcess {
  GuardProcess(identity: .init(pid: pid, started: started ?? UInt64(pid)),
    parent: parent, name: name, bytes: bytes)
}

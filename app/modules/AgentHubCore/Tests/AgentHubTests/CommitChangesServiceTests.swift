import Foundation
import Testing

@testable import AgentHubCore

@Suite("CommitChangesService")
struct CommitChangesServiceTests {
  @Test("Reviewed commits record the live HEAD recovery transition", arguments: [false, true])
  func headRecoveryHistory(linked: Bool) async throws {
    let repo = try CommitTestRepository()
    let linkedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "commit-head-log-\(UUID())")
    defer {
      try? FileManager.default.removeItem(at: linkedURL)
      repo.remove()
    }
    if linked { _ = try repo.git(["worktree", "add", "-b", "task", linkedURL.path]) }
    let worktree = linked ? linkedURL.path : repo.path
    _ = try repo.git(["-C", worktree, "commit", "--allow-empty", "-m", "Previous native commit"])
    let mainHistory = try Data(contentsOf: repo.url.appendingPathComponent(".git/logs/HEAD"))
    try Data("approved".utf8).write(to: URL(fileURLWithPath: worktree + "/tracked"))
    let service = CommitChangesService()
    let snapshot = try await service.prepare(
      sessionID: "history", providerID: "codex", projectPath: worktree)
    let receipt = try await service.commit(snapshot: snapshot, message: "Reviewed commit")
    let log = try String(contentsOfFile: snapshot.gitDirectory + "/logs/HEAD", encoding: .utf8)
    #expect(
      log.split(separator: "\n").last?.hasPrefix("\(snapshot.head) \(receipt.commitID) ") == true)
    #expect(try repo.git(["-C", worktree, "rev-parse", "HEAD@{1}"]) == snapshot.head)
    #expect(try repo.git(["-C", worktree, "rev-parse", "HEAD@{0}"]) == receipt.commitID)
    if linked {
      #expect(
        try Data(contentsOf: repo.url.appendingPathComponent(".git/logs/HEAD")) == mainHistory)
    }
  }

  @Test(
    "HEAD log creation and disabled-log behavior match native Git",
    arguments: ["false", "true", "always", "unset", "shared"], [false, true])
  func headLogSettingsMatchNative(setting: String, existing: Bool) async throws {
    let reviewed = try CommitTestRepository()
    let native = try CommitTestRepository()
    defer {
      reviewed.remove()
      native.remove()
    }
    for repo in [reviewed, native] {
      if setting == "shared" {
        _ = try repo.git(["config", "core.sharedRepository", "group"])
      } else if setting == "unset" {
        _ = try repo.git(["config", "--unset-all", "core.logAllRefUpdates"])
      } else {
        _ = try repo.git(["config", "core.logAllRefUpdates", setting])
      }
      if !existing { try FileManager.default.removeItem(atPath: repo.path + "/.git/logs/HEAD") }
      try repo.write("tracked", "approved")
    }
    let reviewedLog = reviewed.url.appendingPathComponent(".git/logs/HEAD")
    let nativeLog = native.url.appendingPathComponent(".git/logs/HEAD")
    let before = try? Data(contentsOf: reviewedLog)
    let service = CommitChangesService()
    let snapshot = try await reviewed.prepare(service)
    let receipt = try await service.commit(snapshot: snapshot, message: "Reviewed commit")
    _ = try native.git(["add", "--", "tracked"])
    _ = try native.git(["commit", "-m", "Reviewed commit"])
    let reviewedBytes = try? Data(contentsOf: reviewedLog)
    let nativeBytes = try? Data(contentsOf: nativeLog)
    #expect((reviewedBytes != nil) == (nativeBytes != nil))
    if let reviewedBytes, let nativeBytes {
      #expect(reviewedBytes.starts(with: before ?? Data()))
      #expect(reviewedBytes.split(separator: 10).count == nativeBytes.split(separator: 10).count)
      #expect(
        String(decoding: reviewedBytes, as: UTF8.self).contains(
          "\(snapshot.head) \(receipt.commitID) "))
      #expect(
        String(decoding: reviewedBytes, as: UTF8.self).hasSuffix("\tcommit: Reviewed commit\n"))
      let reviewedMode =
        try FileManager.default.attributesOfItem(atPath: reviewedLog.path)[.posixPermissions]
        as? NSNumber
      let nativeMode =
        try FileManager.default.attributesOfItem(atPath: nativeLog.path)[.posixPermissions]
        as? NSNumber
      #expect(reviewedMode == nativeMode)
    }
    #expect(try reviewed.git(["status", "--porcelain"]).isEmpty)
  }

  @Test("Native reflog writes respect the held HEAD lock")
  func concurrentHeadLogWriterIsBlocked() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    let old = try repo.git(["rev-parse", "HEAD"])
    let runner = CommitBarrierRunner { _, arguments, environment in
      if arguments.first == "update-ref", environment["GIT_COMMON_DIR"] != nil {
        #expect(throws: (any Error).self) {
          try repo.git(["reflog", "write", "HEAD", old, old, "Concurrent history write"])
        }
      }
    }
    let service = CommitChangesService(runner: runner)
    let snapshot = try await repo.prepare(service)
    let receipt = try await service.commit(snapshot: snapshot, message: "Reviewed commit")
    let log = try String(contentsOfFile: snapshot.gitDirectory + "/logs/HEAD", encoding: .utf8)
    #expect(log.split(separator: "\n").last?.hasPrefix("\(old) \(receipt.commitID) ") == true)
    #expect(!log.contains("Concurrent history write"))
  }

  @Test("A changed recovery log after publication stays untouched and reports unconfirmed")
  func headLogRecordingFailure() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    let path = repo.path + "/.git/logs/HEAD"
    let previousHistory = try Data(contentsOf: URL(fileURLWithPath: path))
    let concurrentHistory = Data("Concurrent metadata must survive\n".utf8)
    let runner = CommitBarrierRunner { _, arguments, environment in
      if arguments.first == "update-ref", environment["GIT_COMMON_DIR"] != nil {
        try FileManager.default.moveItem(atPath: path, toPath: path + ".saved")
        try concurrentHistory.write(to: URL(fileURLWithPath: path))
      }
    }
    let service = CommitChangesService(runner: runner)
    let snapshot = try await repo.prepare(service)
    do {
      _ = try await service.commit(snapshot: snapshot, message: "Reviewed commit")
      Issue.record("Expected an unconfirmed publication after recovery history changed")
    } catch CommitChangesError.unconfirmed(let commitID, let recoveryPath) {
      #expect(try repo.git(["rev-parse", "HEAD"]) == commitID)
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == concurrentHistory)
      #expect(try Data(contentsOf: URL(fileURLWithPath: path + ".saved")) == previousHistory)
      #expect(FileManager.default.fileExists(atPath: recoveryPath))
      #expect(try repo.index() == snapshot.index)
      await #expect(throws: CommitChangesError.alreadyUsed) {
        try await service.commit(snapshot: snapshot, message: "Replay")
      }
    }
  }

  @Test("An actual HEAD log append failure keeps the published commit unconfirmed")
  func readOnlyHeadLogFailure() async throws {
    let repo = try CommitTestRepository()
    let path = repo.path + "/.git/logs/HEAD"
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
      repo.remove()
    }
    try repo.write("tracked", "approved")
    let originalHistory = try Data(contentsOf: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    do {
      _ = try await service.commit(snapshot: snapshot, message: "Reviewed commit")
      Issue.record("Expected an unconfirmed result because the real HEAD log cannot be appended")
    } catch CommitChangesError.unconfirmed(let commitID, let recoveryPath) {
      #expect(try repo.git(["rev-parse", "HEAD"]) == commitID)
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == originalHistory)
      #expect(FileManager.default.fileExists(atPath: recoveryPath))
      #expect(try repo.index() == snapshot.index)
    }
  }

  @Test("Real commit publishes approved bytes and leaves the ordinary index clean")
  func commitsExactSnapshot() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    try repo.write(":(glob)*\nnew", "new bytes")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    #expect(Set(snapshot.entries.map(\.path)) == ["tracked", ":(glob)*\nnew"])
    let result = try await service.commit(snapshot: snapshot, message: "Save approved files")
    #expect(result.branch == "main")
    #expect(try repo.git(["rev-parse", "HEAD"]) == result.commitID)
    #expect(try repo.git(["show", "HEAD:tracked"]) == "approved")
    #expect(try repo.git(["show", "HEAD::(glob)*\nnew"]) == "new bytes")
    #expect(try repo.git(["status", "--porcelain"]).isEmpty)
    await #expect(throws: CommitChangesError.alreadyUsed) {
      try await service.commit(snapshot: snapshot, message: "Replay")
    }
  }

  @Test("Branch diff alone is not an uncommitted candidate; untracked files are candidates")
  func candidatesAreIndependentOfBranchDiff() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    let service = CommitChangesService()
    #expect(try await repo.prepare(service).entries.isEmpty)
    try repo.write("untracked", "new")
    #expect(try await repo.prepare(service).entries.map(\.path) == ["untracked"])
  }

  @Test(
    "Changing tracked, binary, untracked, mode, or same-count names invalidates approval",
    arguments: ["tracked", "binary", "untracked", "mode", "replacement"])
  func staleContent(kind: String) async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    try repo.write("untracked", "approved")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    switch kind {
    case "binary": try Data([0, 1, 2, 255]).write(to: repo.url.appendingPathComponent("tracked"))
    case "mode":
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: repo.path + "/tracked")
    case "replacement":
      try FileManager.default.removeItem(atPath: repo.path + "/untracked")
      try repo.write("replacement", "approved")
    default: try repo.write(kind, "changed")
    }
    let index = try repo.index()
    await #expect(throws: CommitChangesError.stale) {
      try await service.commit(snapshot: snapshot, message: "Save")
    }
    #expect(try repo.index() == index)
    #expect(try repo.git(["rev-parse", "HEAD"]) == snapshot.head)
  }

  @Test("Symlink targets, deletion tombstones, and delete/recreate identity are bound")
  func fileTypes() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try FileManager.default.createSymbolicLink(
      atPath: repo.path + "/link", withDestinationPath: "/outside/one")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    #expect(snapshot.entries.first?.mode == "120000")
    try FileManager.default.removeItem(atPath: repo.path + "/link")
    try FileManager.default.createSymbolicLink(
      atPath: repo.path + "/link", withDestinationPath: "/outside/two")
    await #expect(throws: CommitChangesError.stale) {
      try await service.commit(snapshot: snapshot, message: "Link")
    }
    try FileManager.default.removeItem(atPath: repo.path + "/link")
    try FileManager.default.removeItem(atPath: repo.path + "/tracked")
    let deletion = try await repo.prepare(service)
    #expect(deletion.entries.first?.mode == "0")
    _ = try await service.commit(snapshot: deletion, message: "Remove file")
    #expect(try repo.git(["status", "--porcelain"]).isEmpty)
  }

  @Test("A staged rename commits both paths and preserves executable mode")
  func rename() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    _ = try repo.git(["mv", "--", "tracked", "-renamed"])
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    #expect(snapshot.entries.first?.originalPath == "tracked")
    _ = try await service.commit(snapshot: snapshot, message: "Rename")
    #expect(try repo.git(["status", "--porcelain"]).isEmpty)
    #expect(try repo.git(["ls-tree", "--name-only", "HEAD"]) == "-renamed")
  }

  @Test("Partial staging is refused without altering the ordinary index")
  func partialStaging() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "staged")
    _ = try repo.git(["add", "--", "tracked"])
    try repo.write("tracked", "unstaged")
    let index = try repo.index()
    await #expect(throws: (any Error).self) { try await repo.prepare(CommitChangesService()) }
    #expect(try repo.index() == index)
  }

  @Test("Unrelated staging after review is retained and rejects the commit")
  func unrelatedStaging() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    try repo.write("other", "staged by someone else")
    _ = try repo.git(["add", "--", "other"])
    let index = try repo.index()
    await #expect(throws: CommitChangesError.stale) {
      try await service.commit(snapshot: snapshot, message: "Save")
    }
    #expect(try repo.index() == index)
    #expect(try repo.git(["show", ":other"]) == "staged by someone else")
  }

  @Test("Live HEAD lock rejects a branch switch while publishing only the approved branch")
  func branchSwitchRace() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    _ = try repo.git(["branch", "other"])
    try repo.write("tracked", "approved")
    let old = try repo.git(["rev-parse", "HEAD"])
    let runner = CommitBarrierRunner { path, arguments, environment in
      if arguments.first == "update-ref", environment["GIT_COMMON_DIR"] != nil {
        #expect(throws: (any Error).self) {
          try repo.git(["symbolic-ref", "HEAD", "refs/heads/other"])
        }
      }
    }
    let service = CommitChangesService(runner: runner)
    let snapshot = try await repo.prepare(service)
    let result = try await service.commit(snapshot: snapshot, message: "Save")
    #expect(try repo.git(["rev-parse", "main"]) == result.commitID)
    #expect(try repo.git(["rev-parse", "other"]) == old)
    #expect(try repo.git(["symbolic-ref", "HEAD"]) == "refs/heads/main")
    #expect(try repo.git(["diff", "--cached", "--name-only"]).isEmpty)
  }

  @Test("Real branch advance at publication fails expected-old comparison")
  func branchAdvanceRace() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    _ = try repo.git(["commit", "--allow-empty", "-m", "External commit"])
    let external = try repo.git(["rev-parse", "HEAD"])
    _ = try repo.git(["reset", "--hard", "HEAD~1"])
    try repo.write("tracked", "approved")
    let siblingGit = repo.url.appendingPathComponent(".git/race-publisher")
    _ = try repo.git(["init", "--bare", siblingGit.path])
    try Data("\(external)\n".utf8).write(to: siblingGit.appendingPathComponent("HEAD"))
    try Data("\(repo.path)/.git\n".utf8).write(to: siblingGit.appendingPathComponent("commondir"))
    let runner = CommitBarrierRunner { _, arguments, environment in
      if arguments.first == "update-ref", environment["GIT_COMMON_DIR"] != nil {
        let output = try CommitGitRunner().run(
          at: repo.path, arguments: ["update-ref", "refs/heads/main", external],
          environment: ["GIT_DIR": siblingGit.path, "GIT_COMMON_DIR": repo.path + "/.git"],
          input: nil)
        #expect(output.status == 0)
      }
    }
    let service = CommitChangesService(runner: runner)
    let snapshot = try await repo.prepare(service)
    let index = try repo.index()
    await #expect(throws: (any Error).self) {
      try await service.commit(snapshot: snapshot, message: "Save")
    }
    #expect(try repo.git(["rev-parse", "HEAD"]) == external)
    #expect(try repo.index() == index)
  }

  @Test("A late edit stays uncommitted while the exact approved bytes commit")
  func lateContentRace() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    let runner = CommitBarrierRunner { _, arguments, environment in
      if arguments.first == "update-ref", environment["GIT_COMMON_DIR"] != nil {
        try repo.write("tracked", "later edit")
      }
    }
    let service = CommitChangesService(runner: runner)
    let snapshot = try await repo.prepare(service)
    _ = try await service.commit(snapshot: snapshot, message: "Save")
    #expect(try repo.git(["show", "HEAD:tracked"]) == "approved")
    #expect(
      try String(contentsOf: repo.url.appendingPathComponent("tracked"), encoding: .utf8)
        == "later edit")
    #expect(try repo.git(["diff", "--cached", "--name-only"]).isEmpty)
    #expect(try repo.git(["diff", "--name-only"]) == "tracked")
  }

  @Test(
    "Hooks execute; a hook that changes contents or index invalidates approval",
    arguments: [
      "exit 1", "printf changed > tracked", "printf changed > tracked\ngit add -- tracked",
    ])
  func hookFailures(script: String) async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    try repo.hook(script)
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    let index = try repo.index()
    await #expect(throws: (any Error).self) {
      try await service.commit(snapshot: snapshot, message: "Save")
    }
    #expect(try repo.git(["rev-parse", "HEAD"]) == snapshot.head)
    #expect(try repo.index() == index)
  }

  @Test("Effective hooksPath is honored and signing failure is not bypassed")
  func signingAndHookConfiguration() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    try FileManager.default.createDirectory(
      atPath: repo.path + "/.git/custom-hooks", withIntermediateDirectories: true)
    _ = try repo.git(["config", "core.hooksPath", ".git/custom-hooks"])
    try repo.hook("exit 1", relativePath: ".git/custom-hooks/pre-commit")
    let service = CommitChangesService()
    let hooked = try await repo.prepare(service)
    await #expect(throws: (any Error).self) {
      try await service.commit(snapshot: hooked, message: "Hook failure")
    }
    try FileManager.default.removeItem(atPath: repo.path + "/.git/custom-hooks/pre-commit")
    _ = try repo.git(["config", "commit.gpgsign", "true"])
    _ = try repo.git(["config", "gpg.program", "/usr/bin/false"])
    let signed = try await repo.prepare(service)
    await #expect(throws: (any Error).self) {
      try await service.commit(snapshot: signed, message: "Signing failure")
    }
    #expect(try repo.git(["rev-parse", "HEAD"]) == signed.head)
  }

  @Test("A lost result after real publication is unconfirmed and preserves the prepared index")
  func unconfirmedPublication() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    let service = CommitChangesService(runner: CommitLostResultRunner())
    let snapshot = try await repo.prepare(service)
    do {
      _ = try await service.commit(snapshot: snapshot, message: "Save")
      Issue.record("Expected an unconfirmed result")
    } catch CommitChangesError.unconfirmed(let commitID, let path) {
      #expect(try repo.git(["rev-parse", "HEAD"]) == commitID)
      #expect(FileManager.default.fileExists(atPath: path))
      await #expect(throws: CommitChangesError.alreadyUsed) {
        try await service.commit(snapshot: snapshot, message: "Replay")
      }
    }
  }

  @Test("Linked worktree commits stay on that worktree and preserve the main index")
  func linkedWorktree() async throws {
    let repo = try CommitTestRepository()
    let linked = FileManager.default.temporaryDirectory.appendingPathComponent(
      "commit-linked-test-\(UUID())")
    defer {
      try? FileManager.default.removeItem(at: linked)
      repo.remove()
    }
    _ = try repo.git(["worktree", "add", "-b", "task", linked.path])
    let mainHead = try repo.git(["rev-parse", "main"])
    let mainIndex = try repo.index()
    try Data("linked bytes".utf8).write(to: linked.appendingPathComponent("tracked"))
    let service = CommitChangesService()
    let snapshot = try await service.prepare(
      sessionID: "linked", providerID: "codex", projectPath: linked.path)
    let receipt = try await service.commit(snapshot: snapshot, message: "Linked changes")
    #expect(receipt.branch == "task")
    #expect(try repo.git(["rev-parse", "main"]) == mainHead)
    #expect(try repo.index() == mainIndex)
    #expect(try repo.git(["show", "task:tracked"]) == "linked bytes")
  }

  @Test("Fully staged and unstaged named files commit together with a clean ordinary index")
  func mixedFiles() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "staged bytes")
    _ = try repo.git(["add", "--", "tracked"])
    try repo.write("new", "unstaged bytes")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    #expect(snapshot.entries.count == 2)
    _ = try await service.commit(snapshot: snapshot, message: "Approved named files")
    #expect(try repo.git(["status", "--porcelain"]).isEmpty)
    #expect(try repo.git(["show", "HEAD:tracked"]) == "staged bytes")
    #expect(try repo.git(["show", "HEAD:new"]) == "unstaged bytes")
  }

  @Test("A switched branch or replaced repository after preparation rejects approval")
  func staleTarget() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    _ = try repo.git(["switch", "-c", "other"])
    await #expect(throws: CommitChangesError.stale) {
      try await service.commit(snapshot: snapshot, message: "Save")
    }
    #expect(try repo.git(["rev-parse", "main"]) == snapshot.head)
    let replacement = try await repo.prepare(service)
    let relocated = repo.path + "-moved"
    try FileManager.default.moveItem(atPath: repo.path, toPath: relocated)
    defer { try? FileManager.default.moveItem(atPath: relocated, toPath: repo.path) }
    await #expect(throws: (any Error).self) {
      try await service.commit(snapshot: replacement, message: "Save")
    }
  }

  @Test("Replacing a repository at the same path cannot reuse its commit approval")
  func replacedRepositoryAtSamePath() async throws {
    let repo = try CommitTestRepository()
    let replacement = try CommitTestRepository()
    defer {
      repo.remove()
      replacement.remove()
    }
    try repo.write("tracked", "approved")
    try replacement.write("tracked", "different repository")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    let relocated = repo.path + "-original"
    try FileManager.default.moveItem(atPath: repo.path, toPath: relocated)
    defer { try? FileManager.default.moveItem(atPath: relocated, toPath: repo.path) }
    try FileManager.default.moveItem(atPath: replacement.path, toPath: repo.path)
    defer { try? FileManager.default.moveItem(atPath: repo.path, toPath: replacement.path) }
    let head = try repo.git(["rev-parse", "HEAD"])
    let index = try repo.index()

    await #expect(throws: CommitChangesError.stale) {
      try await service.commit(snapshot: snapshot, message: "Save")
    }

    #expect(try repo.git(["rev-parse", "HEAD"]) == head)
    #expect(try repo.index() == index)
    #expect(try repo.git(["diff", "--name-only"]) == "tracked")
    #expect(
      try String(contentsOfFile: repo.path + "/tracked", encoding: .utf8)
        == "different repository")
    #expect(!FileManager.default.fileExists(atPath: repo.path + "/.git/HEAD.lock"))
    #expect(!FileManager.default.fileExists(atPath: repo.path + "/.git/index.lock"))
  }

  @Test("Commit temporary directories and runner stream files are private")
  func temporaryPermissions() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    let runner = CommitBarrierRunner { _, arguments, environment in
      guard arguments.first == "commit", let gitDirectory = environment["GIT_DIR"] else { return }
      let parent = URL(fileURLWithPath: gitDirectory).deletingLastPathComponent().path
      let attributes = try FileManager.default.attributesOfItem(atPath: parent)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    // Git's own alias process inspects the already-open stdin/stdout/stderr
    // descriptors used by the real runner, including their containing folder.
    let check =
      "!python3 -c 'import os,stat; [exit(3) for fd in (0,1,2) if stat.S_IMODE(os.fstat(fd).st_mode) != 0o600]'"
    let result = try CommitGitRunner().run(
      at: repo.path, arguments: ["-c", "alias.permission-check=" + check, "permission-check"],
      environment: [:], input: Data("private input".utf8))
    #expect(result.status == 0)
    let service = CommitChangesService(runner: runner)
    _ = try await service.commit(snapshot: repo.prepare(service), message: "Save")
  }

  @Test("A timeout terminates Git and its hook process group")
  func timeoutStopsChildren() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    let runner = CommitGitRunner(timeout: 0.05)
    #expect(throws: (any Error).self) {
      try runner.run(
        at: repo.path,
        arguments: ["-c", "alias.slow=!sleep 0.3; touch should-not-exist", "slow"],
        environment: [:], input: nil)
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(!FileManager.default.fileExists(atPath: repo.path + "/should-not-exist"))
  }

  @Test("Cancellation before execution changes neither HEAD nor index")
  func cancellationBeforeCommit() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try repo.write("tracked", "approved")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    let index = try repo.index()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.commit(snapshot: snapshot, message: "Save")
    }
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(try repo.git(["rev-parse", "HEAD"]) == snapshot.head)
    #expect(try repo.index() == index)
  }

  @Test("A parent-directory symlink replacement refuses approval")
  func parentSymlinkEscape() async throws {
    let repo = try CommitTestRepository()
    defer { repo.remove() }
    try FileManager.default.createDirectory(
      atPath: repo.path + "/folder", withIntermediateDirectories: true)
    try repo.write("folder/new", "approved")
    let service = CommitChangesService()
    let snapshot = try await repo.prepare(service)
    try FileManager.default.removeItem(atPath: repo.path + "/folder")
    try FileManager.default.createSymbolicLink(
      atPath: repo.path + "/folder", withDestinationPath: "/private/tmp")
    await #expect(throws: (any Error).self) {
      try await service.commit(snapshot: snapshot, message: "Save")
    }
    #expect(try repo.git(["rev-parse", "HEAD"]) == snapshot.head)
  }
}

private struct CommitTestRepository: @unchecked Sendable {
  let url: URL
  var path: String { url.path }
  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "commit-service-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    _ = try git(["init", "--initial-branch=main"])
    _ = try git(["config", "user.name", "Commit Test"])
    _ = try git(["config", "user.email", "commit-test@example.invalid"])
    _ = try git(["config", "commit.gpgsign", "false"])
    _ = try git(["config", "core.autocrlf", "false"])
    _ = try git(["config", "core.hooksPath", path + "/.git/hooks"])
    try write("tracked", "baseline")
    _ = try git(["add", "--", "tracked"])
    _ = try git(["commit", "-m", "Baseline"])
  }
  func remove() { try? FileManager.default.removeItem(at: url) }
  func write(_ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: url.appendingPathComponent(path))
  }
  func index() throws -> Data { try Data(contentsOf: url.appendingPathComponent(".git/index")) }
  func prepare(_ service: CommitChangesService) async throws -> CommitChangeSnapshot {
    try await service.prepare(sessionID: "test-session", providerID: "codex", projectPath: path)
  }
  func hook(_ script: String, relativePath: String = ".git/hooks/pre-commit") throws {
    try write(relativePath, "#!/bin/sh\n" + script + "\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: path + "/" + relativePath)
  }
  func git(_ arguments: [String]) throws -> String {
    let result = try CommitGitRunner().run(
      at: path, arguments: arguments,
      environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], input: nil)
    guard result.status == 0 else {
      throw CommitChangesError.unavailable(String(decoding: result.stderr, as: UTF8.self))
    }
    return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
}

private struct CommitBarrierRunner: CommitGitRunning {
  let barrier: @Sendable (String, [String], [String: String]) throws -> Void
  func run(at path: String, arguments: [String], environment: [String: String], input: Data?) throws
    -> CommitGitOutput
  {
    try barrier(path, arguments, environment)
    return try CommitGitRunner().run(
      at: path, arguments: arguments, environment: environment, input: input)
  }
}

private struct CommitLostResultRunner: CommitGitRunning {
  func run(at path: String, arguments: [String], environment: [String: String], input: Data?) throws
    -> CommitGitOutput
  {
    let result = try CommitGitRunner().run(
      at: path, arguments: arguments, environment: environment, input: input)
    if arguments.first == "update-ref", environment["GIT_COMMON_DIR"] != nil, result.status == 0 {
      throw CommitChangesError.unavailable(
        "Simulated lost process result after real ref publication")
    }
    return result
  }
}

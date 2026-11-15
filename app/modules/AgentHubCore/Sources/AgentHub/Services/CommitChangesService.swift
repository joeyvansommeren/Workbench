import CryptoKit
import Darwin
import Foundation

protocol CommitChangesServiceProtocol: Sendable {
  func prepare(sessionID: String, providerID: String, projectPath: String) async throws
    -> CommitChangeSnapshot
  func commit(snapshot: CommitChangeSnapshot, message: String) async throws -> CommitChangesReceipt
}

struct CommitGitOutput: Sendable {
  let status: Int32
  let stdout: Data
  let stderr: Data
}

protocol CommitGitRunning: Sendable {
  func run(at path: String, arguments: [String], environment: [String: String], input: Data?) throws
    -> CommitGitOutput
}

/// Uses argv and binary stdin. File-backed output avoids pipe deadlocks in hooks.
struct CommitGitRunner: CommitGitRunning {
  var timeout: TimeInterval = 60

  func run(at path: String, arguments: [String], environment: [String: String], input: Data?) throws
    -> CommitGitOutput
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workbench-git-\(UUID())")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputURL = directory.appendingPathComponent("stdin")
    let outputURL = directory.appendingPathComponent("stdout")
    let errorURL = directory.appendingPathComponent("stderr")
    try (input ?? Data()).write(to: inputURL)
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)
    for url in [inputURL, outputURL, errorURL] {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    let inputHandle = try FileHandle(forReadingFrom: inputURL)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
      try? inputHandle.close()
      try? outputHandle.close()
      try? errorHandle.close()
    }
    // A child-owned process group lets timeout/cancellation stop Git's hooks
    // too, without signalling the app's inherited process group.
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_adddup2(&actions, inputHandle.fileDescriptor, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, outputHandle.fileDescriptor, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errorHandle.fileDescriptor, STDERR_FILENO)
    guard posix_spawn_file_actions_addchdir_np(&actions, path) == 0 else {
      throw CommitChangesError.unavailable("The worktree directory is unavailable.")
    }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    // An enclosing agent's Git variables must not redirect this operation.
    var variables = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    variables["GIT_OPTIONAL_LOCKS"] = "0"
    variables["GIT_TERMINAL_PROMPT"] = "0"
    variables.merge(environment) { _, value in value }
    let argumentStorage = (["/usr/bin/git"] + arguments).map { strdup($0) }
    let environmentStorage = variables.map { strdup("\($0.key)=\($0.value)") }
    defer {
      for argument in argumentStorage { free(argument) }
      for variable in environmentStorage { free(variable) }
    }
    var argv = argumentStorage + [nil]
    var envp = environmentStorage + [nil]
    var processID: pid_t = 0
    let launch = posix_spawn(&processID, "/usr/bin/git", &actions, &attributes, &argv, &envp)
    guard launch == 0 else {
      throw CommitChangesError.unavailable("Git could not start in this worktree.")
    }
    let deadline = Date().addingTimeInterval(timeout)
    var status: Int32 = 0
    while true {
      let observed = waitpid(processID, &status, WNOHANG)
      if observed == processID { break }
      if observed < 0 {
        if errno == EINTR { continue }
        throw CommitChangesError.unavailable(
          "Git's completion could not be confirmed. Check the repository before trying again.")
      }
      if Task.isCancelled || Date() >= deadline {
        kill(-processID, SIGTERM)
        usleep(20_000)
        kill(-processID, SIGKILL)
        waitpid(processID, &status, 0)
        throw CommitChangesError.unavailable(
          "Git did not finish. Review the current changes before trying again.")
      }
      usleep(10_000)
    }
    return CommitGitOutput(
      status: (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f),
      stdout: try Data(contentsOf: outputURL), stderr: try Data(contentsOf: errorURL))
  }
}

/// Normal `git commit` runs against a private HEAD/index with the captured config,
/// hooks and signing settings. Only its validated tree may enter the live repository.
/// Live HEAD/index locks prevent target switches; publication compares the bound branch OID.
actor CommitChangesService: CommitChangesServiceProtocol {
  private let runner: any CommitGitRunning
  private var issued: [UUID: CommitChangeSnapshot] = [:]
  private let maximumBytes = 32 * 1024 * 1024

  init(runner: any CommitGitRunning = CommitGitRunner()) { self.runner = runner }

  func prepare(sessionID: String, providerID: String, projectPath: String) throws
    -> CommitChangeSnapshot
  {
    let snapshot = try capture(
      sessionID: sessionID, providerID: providerID, projectPath: projectPath)
    // Retain the approved value itself, so a caller cannot substitute fields
    // while reusing its fingerprint. Bound memory for abandoned review sheets.
    if issued.count >= 8, let oldest = issued.keys.first { issued.removeValue(forKey: oldest) }
    issued[snapshot.id] = snapshot
    return snapshot
  }

  func commit(snapshot: CommitChangeSnapshot, message: String) throws -> CommitChangesReceipt {
    guard issued.removeValue(forKey: snapshot.id) == snapshot else {
      throw CommitChangesError.alreadyUsed
    }
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CommitChangesError.unavailable("Enter a commit message, then review the changes again.")
    }
    guard !snapshot.entries.isEmpty else {
      throw CommitChangesError.unavailable("There are no uncommitted files in this worktree.")
    }
    try checkCurrent(snapshot)
    try Task.checkCancellation()

    let headLockPath = snapshot.gitDirectory + "/HEAD.lock"
    let headDescriptor = open(headLockPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard headDescriptor >= 0 else {
      throw CommitChangesError.unavailable(
        "Git is changing this worktree's branch. Wait, then review the changes again.")
    }
    let headLockIdentity = try lockIdentityValue(headLockPath)
    defer {
      close(headDescriptor)
      if (try? lockIdentityValue(headLockPath)) == headLockIdentity { unlink(headLockPath) }
    }
    let lockPath = snapshot.gitDirectory + "/index.lock"
    let descriptor = open(lockPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw CommitChangesError.unavailable(
        "Git is using this worktree. Wait for that operation, then review the changes again.")
    }
    let lockIdentity = try lockIdentityValue(lockPath)
    var preserveLock = false
    defer {
      close(descriptor)
      if !preserveLock, (try? lockIdentityValue(lockPath)) == lockIdentity { unlink(lockPath) }
    }
    try checkCurrent(snapshot)

    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workbench-commit-\(UUID())")
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let privateGit = temporary.appendingPathComponent("git").path
    _ = try git(
      snapshot.worktreePath,
      ["init", "--bare", "--quiet", "--object-format=sha1", "--ref-format=files", privateGit])
    let environment = try isolatedEnvironment(snapshot, gitDirectory: privateGit)
    try Data("ref: \(snapshot.branchRef)\n".utf8).write(
      to: URL(fileURLWithPath: privateGit + "/HEAD"))
    let privateRef = URL(fileURLWithPath: privateGit + "/" + snapshot.branchRef)
    try FileManager.default.createDirectory(
      at: privateRef.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("\(snapshot.head)\n".utf8).write(to: privateRef)
    let headHistory = try prepareHeadHistory(snapshot, privateGit: privateGit)
    _ = try git(snapshot.worktreePath, ["read-tree", snapshot.head], environment)
    let treeEntries = try objectEntries(snapshot, environment: environment)
    _ = try git(
      snapshot.worktreePath, ["update-index", "-z", "--index-info"], environment, treeEntries)
    let approvedTree = try value(snapshot.worktreePath, ["write-tree"], environment)

    // Preserve all ordinary index entries outside the approved set. This index
    // becomes visible only after the bound ref transaction succeeds.
    let reconciledIndex = temporary.appendingPathComponent("reconciled-index")
    try snapshot.index.write(to: reconciledIndex)
    var reconciliationEnvironment = environment
    reconciliationEnvironment["GIT_INDEX_FILE"] = reconciledIndex.path
    _ = try git(
      snapshot.worktreePath, ["update-index", "-z", "--index-info"], reconciliationEnvironment,
      treeEntries)
    let reconciledBytes = try Data(contentsOf: reconciledIndex)
    try writeAll(reconciledBytes, to: descriptor)
    guard fsync(descriptor) == 0 else {
      throw CommitChangesError.unavailable("The prepared Git index could not be saved.")
    }

    try checkCurrent(snapshot)
    _ = try git(snapshot.worktreePath, ["commit", "--file=-"], environment, Data(message.utf8))
    let commitID = try value(snapshot.worktreePath, ["rev-parse", "HEAD"], environment)
    let committedTree = try value(snapshot.worktreePath, ["rev-parse", "HEAD^{tree}"], environment)
    let parents = try value(
      snapshot.worktreePath, ["show", "-s", "--format=%P", "HEAD"], environment)
    guard committedTree == approvedTree, parents == snapshot.head,
      try value(snapshot.worktreePath, ["write-tree"], environment) == approvedTree
    else {
      throw CommitChangesError.unavailable(
        "A Git hook changed the approved files. Review the changes again.")
    }
    let headHistoryEntry = try generatedHeadHistory(
      headHistory, privateGit: privateGit, oldCommit: snapshot.head, newCommit: commitID)
    try checkCurrent(snapshot)
    try Task.checkCancellation()
    guard try lockIdentityValue(lockPath) == lockIdentity else { throw CommitChangesError.stale }

    // HEAD.lock prevents normal Git tools from switching this worktree. Publish
    // from a private detached HEAD so Git does not acquire our live HEAD.lock a
    // second time for its implicit reflog update. The branch still uses Git's
    // expected-old-value comparison and ref lock in the shared ref store.
    guard try lockIdentityValue(headLockPath) == headLockIdentity else {
      throw CommitChangesError.stale
    }
    try validateHeadHistory(headHistory)
    try Data("\(commitID)\n".utf8).write(to: URL(fileURLWithPath: privateGit + "/HEAD"))
    try Data("\(snapshot.commonDirectory)\n".utf8).write(
      to: URL(fileURLWithPath: privateGit + "/commondir"))
    var publicationEnvironment = environment
    publicationEnvironment["GIT_COMMON_DIR"] = snapshot.commonDirectory
    do {
      _ = try git(
        snapshot.worktreePath,
        [
          "update-ref", "--no-deref", "-m", "commit: Workbench reviewed changes",
          snapshot.branchRef, commitID, snapshot.head,
        ],
        publicationEnvironment)
    } catch {
      // A timeout/transport failure can happen after Git published the commit.
      // Keep the prepared index for recovery rather than claiming no commit.
      let current = try? value(snapshot.worktreePath, ["rev-parse", snapshot.branchRef])
      let containsCommit =
        (try? runner.run(
          at: snapshot.worktreePath,
          arguments: ["merge-base", "--is-ancestor", commitID, snapshot.branchRef],
          environment: [:], input: nil
        ).status) == 0
      if current == nil || current == commitID || containsCommit {
        preserveLock = true
        throw CommitChangesError.unconfirmed(commitID: commitID, recoveryPath: lockPath)
      }
      throw error
    }
    do {
      guard try lockIdentityValue(headLockPath) == headLockIdentity else {
        throw CommitChangesError.stale
      }
      try appendHeadHistory(headHistoryEntry, to: headHistory, privateGit: privateGit)
    } catch {
      // Publication cannot be rolled back safely. Keep the prepared index and
      // report uncertainty if the worktree's required recovery entry is missing.
      preserveLock = true
      throw CommitChangesError.unconfirmed(commitID: commitID, recoveryPath: lockPath)
    }
    // Like Git's own commit, ref publication precedes the final index rename.
    // Never roll back a published ref or overwrite a lock we no longer own.
    guard (try? lockIdentityValue(lockPath)) == lockIdentity,
      rename(lockPath, snapshot.gitDirectory + "/index") == 0
    else {
      preserveLock = true
      throw CommitChangesError.unconfirmed(commitID: commitID, recoveryPath: lockPath)
    }
    return CommitChangesReceipt(
      commitID: commitID, branch: snapshot.branch, paths: snapshot.entries.map(\.path))
  }

  private struct HeadHistory {
    let path: String
    let fileIdentity: String?
    let directoryIdentity: String?
  }

  private func prepareHeadHistory(_ snapshot: CommitChangeSnapshot, privateGit: String) throws
    -> HeadHistory
  {
    let directory = snapshot.gitDirectory + "/logs"
    let path = directory + "/HEAD"
    let history = HeadHistory(
      path: path, fileIdentity: try historyIdentity(path, type: S_IFREG),
      directoryIdentity: try historyIdentity(directory, type: S_IFDIR))
    // Native Git appends existing reflogs even when automatic creation is off.
    // Seed only that existence; Git generates the identity, time, message, mode,
    // and create/no-create decision for the normal commit using captured config.
    if history.fileIdentity != nil {
      let privateDirectory = privateGit + "/logs"
      try FileManager.default.createDirectory(
        atPath: privateDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let privatePath = privateDirectory + "/HEAD"
      let descriptor = open(privatePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw CommitChangesError.stale }
      defer { close(descriptor) }
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
      // Start from the existing mode so Git applies shared-repository settings
      // accurately. This private seed must be writable; the real append still
      // uses the live file's own permissions and fails rather than relaxing them.
      guard fchmod(descriptor, mode_t(mode) | S_IWUSR) == 0 else {
        throw CommitChangesError.stale
      }
    }
    return history
  }

  private func generatedHeadHistory(
    _ history: HeadHistory, privateGit: String, oldCommit: String, newCommit: String
  ) throws -> Data? {
    let path = privateGit + "/logs/HEAD"
    guard try historyIdentity(path, type: S_IFREG) != nil else {
      guard history.fileIdentity == nil else { throw CommitChangesError.stale }
      return nil
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let entries = data.split(separator: 10)
    guard entries.count == 1, data.last == 10,
      entries[0].starts(with: Data("\(oldCommit) \(newCommit) ".utf8))
    else {
      throw CommitChangesError.unavailable(
        "A Git hook changed the commit's recovery history. Review the repository in the terminal.")
    }
    return data
  }

  private func validateHeadHistory(_ history: HeadHistory) throws {
    let directory = URL(fileURLWithPath: history.path).deletingLastPathComponent().path
    let currentDirectory = try historyIdentity(directory, type: S_IFDIR)
    guard history.directoryIdentity == nil || currentDirectory == history.directoryIdentity,
      try historyIdentity(history.path, type: S_IFREG) == history.fileIdentity
    else { throw CommitChangesError.stale }
  }

  private func appendHeadHistory(_ entry: Data?, to history: HeadHistory, privateGit: String) throws
  {
    guard let entry else { return }
    try validateHeadHistory(history)
    let directory = URL(fileURLWithPath: history.path).deletingLastPathComponent().path
    let manager = FileManager.default
    if try historyIdentity(directory, type: S_IFDIR) == nil {
      let attributes = try manager.attributesOfItem(atPath: privateGit + "/logs")
      try manager.createDirectory(
        atPath: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: attributes[.posixPermissions] ?? 0o755])
    }
    let attributes = try manager.attributesOfItem(atPath: privateGit + "/logs/HEAD")
    let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
    let flags =
      O_WRONLY | O_APPEND | O_NOFOLLOW
      | (history.fileIdentity == nil ? O_CREAT | O_EXCL : 0)
    let descriptor = open(history.path, flags, mode_t(mode))
    guard descriptor >= 0 else { throw CommitChangesError.stale }
    defer { close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
      try lockIdentityValue(history.path) == "\(opened.st_dev):\(opened.st_ino)"
    else { throw CommitChangesError.stale }
    if opened.st_mode & 0o7777 != mode_t(mode), fchmod(descriptor, mode_t(mode)) != 0 {
      throw CommitChangesError.stale
    }
    // HEAD.lock excludes native reflog writers. O_APPEND preserves existing
    // history; never replace a log or relax the live ref lock to call reflog write.
    try writeAll(entry, to: descriptor)
    guard fsync(descriptor) == 0 else { throw CommitChangesError.stale }
  }

  private func historyIdentity(_ path: String, type: mode_t) throws -> String? {
    var info = stat()
    if lstat(path, &info) != 0 {
      guard errno == ENOENT else { throw CommitChangesError.stale }
      return nil
    }
    guard info.st_mode & S_IFMT == type else {
      throw CommitChangesError.unavailable(
        "The worktree's Git recovery history uses an unsupported path. Review it in the terminal.")
    }
    return try identity(path)
  }

  private func capture(sessionID: String, providerID: String, projectPath: String) throws
    -> CommitChangeSnapshot
  {
    let root = try value(projectPath, ["rev-parse", "--show-toplevel"])
    let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    let gitDirectory = try value(root, ["rev-parse", "--absolute-git-dir"])
    let commonDirectory = try value(
      root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    let branch = try value(root, ["symbolic-ref", "--quiet", "HEAD"])
    guard branch.hasPrefix("refs/heads/") else {
      throw CommitChangesError.unavailable("Switch to a local branch before reviewing a commit.")
    }
    let head = try value(root, ["rev-parse", "--verify", "HEAD^{commit}"])
    guard head.count == 40 else {
      throw CommitChangesError.unavailable(
        "This repository's object format is not supported for reviewed commits.")
    }
    for marker in [
      "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer",
    ] {
      guard !FileManager.default.fileExists(atPath: gitDirectory + "/" + marker) else {
        throw CommitChangesError.unavailable(
          "Finish the current merge, rebase, or cherry-pick before reviewing a commit.")
      }
    }
    let configuration = try git(root, ["config", "--null", "--list", "--includes"])
    let settings = try configurationPairs(configuration)
    guard !settings.contains(where: { $0.0 == "core.sparsecheckout" && $0.1 != "false" }) else {
      throw CommitChangesError.unavailable(
        "Reviewed commits do not support sparse worktrees yet. Commit from the terminal.")
    }
    guard !settings.contains(where: { $0.0 == "core.autocrlf" && $0.1 != "false" }) else {
      throw CommitChangesError.unavailable(
        "This worktree converts file contents on commit. Commit from the terminal.")
    }
    let indexURL = URL(fileURLWithPath: gitDirectory + "/index")
    guard try value(root, ["rev-parse", "--shared-index-path"]).isEmpty else {
      throw CommitChangesError.unavailable(
        "Reviewed commits do not support a split Git index. Commit from the terminal.")
    }
    let index = try Data(contentsOf: indexURL)
    let tracked = try git(root, ["ls-files", "--stage", "-z"])
    guard
      try !nulStrings(tracked).contains(where: {
        $0.hasPrefix("160000 ")
          || !($0.components(separatedBy: "\t").first?.hasSuffix(" 0") ?? false)
      })
    else {
      throw CommitChangesError.unavailable(
        "Reviewed commits do not support submodules or unresolved conflicts. Commit from the terminal."
      )
    }
    let flags = try nulStrings(git(root, ["ls-files", "-v", "-z"]))
    guard !flags.contains(where: { $0.hasPrefix("S ") || $0.first?.isLowercase == true }) else {
      throw CommitChangesError.unavailable(
        "Some files are hidden from Git status. Remove skip-worktree or assume-unchanged flags before reviewing a commit."
      )
    }
    let status = try nulStrings(
      git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]))
    var entries: [CommitChangeSnapshot.Entry] = []
    var total = index.count + configuration.count
    var offset = 0
    while offset < status.count {
      let record = status[offset]
      offset += 1
      guard record.utf8.count > 3 else { throw CommitChangesError.stale }
      let code = String(record.prefix(2))
      let path = String(record.dropFirst(3))
      let chars = Array(code)
      guard !code.contains("U"), code != "AA", code != "DD" else {
        throw CommitChangesError.unavailable("Resolve file conflicts before reviewing a commit.")
      }
      guard code == "??" || chars[0] == " " || chars[1] == " " else {
        throw CommitChangesError.unavailable(
          "\(path.debugDescription) has staged and unstaged changes. Commit it from the terminal or finish staging it first."
        )
      }
      var originalPath: String?
      if code.contains("R") || code.contains("C") {
        guard offset < status.count else { throw CommitChangesError.stale }
        originalPath = status[offset]
        offset += 1
        try validatePath(originalPath!, root: canonicalRoot)
        guard !FileManager.default.fileExists(atPath: canonicalRoot + "/" + originalPath!) else {
          throw CommitChangesError.unavailable(
            "The rename source still exists. Review and commit this rename from the terminal.")
        }
      }
      try validatePath(path, root: canonicalRoot)
      let file = try fileContents(path, root: canonicalRoot)
      total += file.bytes?.count ?? 0
      guard total <= maximumBytes else {
        throw CommitChangesError.unavailable(
          "These changes are too large for a reviewed commit. Commit from the terminal.")
      }
      entries.append(
        .init(
          path: path, originalPath: originalPath, status: code, mode: file.mode, bytes: file.bytes,
          fileIdentity: file.identity))
    }
    entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    guard Set(entries.map(\.path)).count == entries.count else {
      throw CommitChangesError.unavailable(
        "A path has multiple staged versions. Review and commit it from the terminal.")
    }
    if !entries.isEmpty {
      let attributes = try nulStrings(
        git(
          root, ["check-attr", "-z", "--stdin", "filter", "text", "eol", "working-tree-encoding"],
          [:], Data(entries.map { $0.path + "\0" }.joined().utf8)))
      for position in stride(from: 2, to: attributes.count, by: 3) {
        guard ["unspecified", "unset"].contains(attributes[position]) else {
          throw CommitChangesError.unavailable(
            "Git attributes convert these file contents. Commit from the terminal.")
        }
      }
    }
    let directoryIdentity = try [canonicalRoot, gitDirectory, commonDirectory].map(identity).joined(
      separator: ":")
    var identityData = [
      sessionID, providerID, projectPath, canonicalRoot, gitDirectory, commonDirectory,
      directoryIdentity, branch, head,
    ].map { Data($0.utf8) }
    identityData += [index, configuration]
    for entry in entries {
      identityData += [
        entry.path, entry.originalPath ?? "", entry.status, entry.mode, entry.fileIdentity,
      ].map { Data($0.utf8) }
      identityData.append(entry.bytes ?? Data())
    }
    var digest = SHA256()
    for part in identityData {
      var size = UInt64(part.count).bigEndian
      withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
      digest.update(data: part)
    }
    let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return CommitChangeSnapshot(
      id: UUID(), sessionID: sessionID, providerID: providerID, requestedPath: projectPath,
      worktreePath: canonicalRoot, gitDirectory: gitDirectory, commonDirectory: commonDirectory,
      directoryIdentity: directoryIdentity, branchRef: branch, head: head, index: index,
      configuration: configuration, entries: entries, fingerprint: fingerprint)
  }

  private func checkCurrent(_ snapshot: CommitChangeSnapshot) throws {
    let current = try capture(
      sessionID: snapshot.sessionID, providerID: snapshot.providerID,
      projectPath: snapshot.requestedPath)
    guard current.fingerprint == snapshot.fingerprint else { throw CommitChangesError.stale }
  }

  private func isolatedEnvironment(_ snapshot: CommitChangeSnapshot, gitDirectory: String) throws
    -> [String: String]
  {
    var pairs = try configurationPairs(snapshot.configuration).filter {
      !["core.worktree", "core.bare", "core.repositoryformatversion", "core.hookspath"].contains(
        $0.0)
        && !$0.0.hasPrefix("include.") && !$0.0.hasPrefix("includeif.")
        && !$0.0.hasPrefix("extensions.")
    }
    let hooks = try value(
      snapshot.worktreePath, ["rev-parse", "--path-format=absolute", "--git-path", "hooks"])
    pairs += [
      ("core.worktree", snapshot.worktreePath), ("core.bare", "false"), ("core.hooksPath", hooks),
    ]
    var environment = [
      "GIT_DIR": gitDirectory, "GIT_WORK_TREE": snapshot.worktreePath,
      "GIT_OBJECT_DIRECTORY": snapshot.commonDirectory + "/objects", "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_COUNT": String(pairs.count),
    ]
    for (index, pair) in pairs.enumerated() {
      environment["GIT_CONFIG_KEY_\(index)"] = pair.0
      environment["GIT_CONFIG_VALUE_\(index)"] = pair.1
    }
    return environment
  }

  private func objectEntries(_ snapshot: CommitChangeSnapshot, environment: [String: String]) throws
    -> Data
  {
    var records = Data()
    for entry in snapshot.entries {
      if let original = entry.originalPath {
        records.append(Data("0 \(String(repeating: "0", count: 40))\t\(original)\0".utf8))
      }
      let oid: String
      if let bytes = entry.bytes {
        oid = try value(
          snapshot.worktreePath, ["hash-object", "-w", "--stdin"], environment, bytes)
      } else {
        oid = String(repeating: "0", count: 40)
      }
      records.append(Data("\(entry.mode) \(oid)\t\(entry.path)\0".utf8))
    }
    return records
  }

  private func configurationPairs(_ data: Data) throws -> [(String, String)] {
    try nulStrings(data).map {
      guard let separator = $0.firstIndex(of: "\n") else { return ($0, "true") }
      return (String($0[..<separator]), String($0[$0.index(after: separator)...]))
    }
  }

  private func validatePath(_ path: String, root: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.hasPrefix("/"), !components.isEmpty,
      !components.contains(where: {
        $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git"
      })
    else { throw CommitChangesError.unavailable("Git returned an unsupported file path.") }
    var parent = root
    for component in components.dropLast() {
      parent += "/" + component
      var info = stat()
      guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        throw CommitChangesError.unavailable(
          "A file's parent is missing or is a symbolic link. Review the path from the terminal.")
      }
    }
  }

  private func fileContents(_ path: String, root: String) throws -> (
    mode: String, bytes: Data?, identity: String
  ) {
    let absolute = root + "/" + path
    var info = stat()
    if lstat(absolute, &info) != 0 {
      guard errno == ENOENT else {
        throw CommitChangesError.unavailable("A changed file could not be read.")
      }
      return ("0", nil, "deleted")
    }
    let before = try identity(absolute)
    let bytes: Data
    let mode: String
    switch info.st_mode & S_IFMT {
    case S_IFREG:
      guard info.st_size <= maximumBytes else {
        throw CommitChangesError.unavailable("A changed file is too large for a reviewed commit.")
      }
      let descriptor = open(absolute, O_RDONLY | O_NOFOLLOW)
      guard descriptor >= 0 else { throw CommitChangesError.stale }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      var opened = stat()
      guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev,
        opened.st_ino == info.st_ino
      else {
        throw CommitChangesError.stale
      }
      bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
      guard bytes.count <= maximumBytes else {
        throw CommitChangesError.unavailable("A changed file is too large for a reviewed commit.")
      }
      mode = info.st_mode & S_IXUSR == 0 ? "100644" : "100755"
    case S_IFLNK:
      bytes = Data(try FileManager.default.destinationOfSymbolicLink(atPath: absolute).utf8)
      mode = "120000"
    default:
      throw CommitChangesError.unavailable(
        "A changed path is not a regular file or symbolic link. Commit from the terminal.")
    }
    guard before == (try identity(absolute)) else { throw CommitChangesError.stale }
    try validatePath(path, root: root)
    return (mode, bytes, before)
  }

  private func identity(_ path: String) throws -> String {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw CommitChangesError.stale }
    // Directory mtime changes when our lock is created; device/inode identify it.
    if info.st_mode & S_IFMT == S_IFDIR { return "\(info.st_dev):\(info.st_ino)" }
    return
      "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
  }

  private func lockIdentityValue(_ path: String) throws -> String {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw CommitChangesError.stale }
    return "\(info.st_dev):\(info.st_ino)"
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        guard count > 0 else {
          throw CommitChangesError.unavailable("The prepared Git index could not be saved.")
        }
        offset += count
      }
    }
  }

  private func nulStrings(_ data: Data) throws -> [String] {
    try data.split(separator: 0).map {
      guard let value = String(data: $0, encoding: .utf8) else {
        throw CommitChangesError.unavailable(
          "This repository has a file name that cannot be displayed safely.")
      }
      return value
    }
  }

  private func value(
    _ path: String, _ arguments: [String], _ environment: [String: String] = [:],
    _ input: Data? = nil
  ) throws -> String {
    String(decoding: try git(path, arguments, environment, input), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }

  private func git(
    _ path: String, _ arguments: [String], _ environment: [String: String] = [:],
    _ input: Data? = nil
  ) throws -> Data {
    let output = try runner.run(
      at: path, arguments: arguments, environment: environment, input: input)
    guard output.status == 0 else {
      let details = String(decoding: output.stderr.prefix(2_000), as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      throw CommitChangesError.unavailable(
        details.isEmpty
          ? "Git could not complete this operation. Review the repository in the terminal."
          : "Git could not complete this operation. \(details)")
    }
    return output.stdout
  }
}

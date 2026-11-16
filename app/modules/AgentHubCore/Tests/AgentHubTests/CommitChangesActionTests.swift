import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("CommitChangesAction")
struct CommitChangesActionTests {
  @Test("Preparation is not approval and an empty message cannot commit")
  func preparationRequiresApproval() async {
    let service = CommitReviewStub()
    let model = model(service)
    await model.prepare()
    #expect(model.phase == .prepared)
    #expect(!model.canCommit)
    await model.commit()
    #expect(await service.commitCalls == 0)
    model.message = "Save reviewed changes"
    #expect(model.canCommit)
    #expect(model.receipt == nil)
  }

  @Test(
    "A snapshot for another session, provider, or folder cannot be approved",
    arguments: ["session", "provider", "folder"])
  func wrongReviewTarget(field: String) async {
    let service = CommitReviewStub(wrongTargetField: field)
    let model = model(service)
    model.message = "Save reviewed changes"
    await model.prepare()
    await model.commit()
    #expect(model.phase == .failed)
    #expect(model.snapshot == nil)
    #expect(model.receipt == nil)
    #expect(!model.canCommit)
    #expect(model.error?.contains("different session or folder") == true)
    #expect(await service.commitCalls == 0)
  }

  @Test("A stale approval stops with a reason and cannot be retried")
  func staleApproval() async {
    let service = CommitReviewStub(commitError: .stale)
    let model = model(service)
    await model.prepare()
    model.message = "Save reviewed changes"
    await model.commit()
    await model.commit()
    #expect(model.phase == .failed)
    #expect(model.receipt == nil)
    #expect(!model.canCommit)
    #expect(model.error == CommitChangesError.stale.localizedDescription)
    #expect(await service.commitCalls == 1)
  }

  @Test("Repeat confirm dispatches one commit and verifies a receipt")
  func duplicateConfirm() async {
    let service = CommitReviewStub()
    let model = model(service)
    await model.prepare()
    model.message = "Save reviewed changes"
    let first = Task { await model.commit() }
    while model.phase == .prepared { await Task.yield() }
    await model.commit()
    await first.value
    #expect(await service.commitCalls == 1)
    #expect(model.phase == .committed)
    #expect(model.receipt?.commitID == "verified-commit")
  }

  @Test("A session switch invalidates an unapproved review")
  func switchedSession() async {
    let service = CommitReviewStub()
    let model = model(service)
    await model.prepare()
    model.message = "Save reviewed changes"
    model.invalidate()
    await model.commit()
    #expect(model.phase == .failed)
    #expect(!model.canCommit)
    #expect(await service.commitCalls == 0)
  }

  @Test("An unconfirmed publication never shows success or enables a retry")
  func unconfirmed() async {
    let service = CommitReviewStub(failsAfterPublication: true)
    let model = model(service)
    await model.prepare()
    model.message = "Save reviewed changes"
    await model.commit()
    #expect(model.phase == .unconfirmed)
    #expect(model.receipt == nil)
    #expect(!model.canCommit)
  }

  private func model(_ service: CommitReviewStub) -> CommitChangesReviewModel {
    CommitChangesReviewModel(
      sessionID: "session", providerID: "codex", projectPath: "/example", service: service)
  }
}

private actor CommitReviewStub: CommitChangesServiceProtocol {
  private(set) var commitCalls = 0
  let failsAfterPublication: Bool
  let wrongTargetField: String?
  let commitError: CommitChangesError?

  init(
    failsAfterPublication: Bool = false, wrongTargetField: String? = nil,
    commitError: CommitChangesError? = nil
  ) {
    self.failsAfterPublication = failsAfterPublication
    self.wrongTargetField = wrongTargetField
    self.commitError = commitError
  }

  func prepare(sessionID: String, providerID: String, projectPath: String) -> CommitChangeSnapshot {
    CommitChangeSnapshot(
      id: UUID(), sessionID: wrongTargetField == "session" ? "another-session" : sessionID,
      providerID: wrongTargetField == "provider" ? "claude" : providerID,
      requestedPath: wrongTargetField == "folder" ? "/another-folder" : projectPath,
      worktreePath: projectPath, gitDirectory: projectPath + "/.git",
      commonDirectory: projectPath + "/.git",
      directoryIdentity: "identity", branchRef: "refs/heads/main", head: "baseline", index: Data(),
      configuration: Data(),
      entries: [
        .init(
          path: "file.swift", originalPath: nil, status: " M", mode: "100644",
          bytes: Data("approved".utf8), fileIdentity: "file")
      ],
      fingerprint: "fingerprint")
  }

  func commit(snapshot: CommitChangeSnapshot, message: String) async throws -> CommitChangesReceipt
  {
    commitCalls += 1
    if let commitError { throw commitError }
    try await Task.sleep(for: .milliseconds(10))
    if failsAfterPublication {
      throw CommitChangesError.unconfirmed(
        commitID: "maybe-committed", recoveryPath: "/example/.git/index.lock")
    }
    return CommitChangesReceipt(
      commitID: "verified-commit", branch: snapshot.branch, paths: snapshot.entries.map(\.path))
  }
}

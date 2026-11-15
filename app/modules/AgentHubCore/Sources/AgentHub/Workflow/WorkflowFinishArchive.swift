import AgentHubGitHub
import Foundation

struct WorkflowFinishArchiveRecord: Codable, Sendable, Equatable {
  let workflowID: String
  let repositoryPath: String
  let branchName: String
  let pullRequestURL: String
  let pullRequestHeadSHA: String
  let archivedAt: Date
  var restoredAt: Date? = nil

  func matches(_ branch: DetectedBranchWorkflow, workflowID: String) -> Bool {
    self.workflowID == workflowID && repositoryPath == branch.repositoryPath
      && branchName == branch.branchName && pullRequestURL == branch.pullRequest?.url
      && pullRequestHeadSHA == branch.pullRequest?.headSHA
  }
}

protocol WorkflowFinishArchiveStoring: Sendable {
  func saveWorkflowFinishArchive(_ record: WorkflowFinishArchiveRecord) async throws
  func loadWorkflowFinishArchives() async throws -> [WorkflowFinishArchiveRecord]
}

/// Task-wide archive is separate from session/process/file cleanup.
enum WorkflowFinishArchivePolicy {
  static func wasRestored(_ record: WorkflowFinishArchiveRecord, among saved: [WorkflowFinishArchiveRecord]) -> Bool {
    saved.contains {
      $0.workflowID == record.workflowID && $0.repositoryPath == record.repositoryPath
        && $0.branchName == record.branchName && $0.pullRequestURL == record.pullRequestURL
        && $0.pullRequestHeadSHA == record.pullRequestHeadSHA && $0.restoredAt != nil
    }
  }

  static func canArchive(_ branches: [DetectedBranchWorkflow]) -> Bool {
    !branches.isEmpty && branches.allSatisfy { branch in
      guard branch.branchName?.isEmpty == false, branch.pullRequest?.state == .merged,
        branch.pullRequest?.headSHA?.isEmpty == false else { return false }
      return !(branch.implementerSessions + branch.reviewerSessions).contains { $0.session.isActive }
    }
  }
}

protocol WorkflowFinishArchivePlanning: Sendable {
  func records(workflowID: String, branches: [DetectedBranchWorkflow]) async -> [WorkflowFinishArchiveRecord]
}

/// Resolves every branch from live disk and the shared observer before archiving.
actor WorkflowFinishArchivePlanner: WorkflowFinishArchivePlanning {
  private let observer: any GitHubPRObservationServiceProtocol
  private let inspector: any FinishGitInspecting

  init(observer: any GitHubPRObservationServiceProtocol, inspector: any FinishGitInspecting) {
    self.observer = observer
    self.inspector = inspector
  }

  func records(workflowID: String, branches: [DetectedBranchWorkflow]) async -> [WorkflowFinishArchiveRecord] {
    guard WorkflowFinishArchivePolicy.canArchive(branches) else { return [] }
    var records: [WorkflowFinishArchiveRecord] = []
    for branch in branches {
      guard let branchName = branch.branchName,
        let assignment = branch.primaryImplementer ?? branch.primaryReviewer,
        let safety = try? await inspector.inspect(at: assignment.session.projectPath),
        safety.branch == branchName, !safety.hasUncommittedChanges else { return [] }
      let snapshot = await FinishGitHubSnapshotReader.read(service: observer,
        path: branch.repositoryPath, branch: branchName)
      guard let snapshot, snapshot.state == .ready, !snapshot.isStale,
        FinishGitHubSnapshotReader.matches(snapshot, path: branch.repositoryPath, branch: branchName),
        snapshot.lastRefreshedAt.map({ Date().timeIntervalSince($0) <= 120 }) == true,
        let pr = snapshot.pullRequest, pr.stateKind == .merged,
        pr.headRefName == branchName, pr.url == branch.pullRequest?.url,
        let head = pr.headRefOid, head == safety.head,
        head == branch.pullRequest?.headSHA else { return [] }
      records.append(WorkflowFinishArchiveRecord(workflowID: workflowID,
        repositoryPath: branch.repositoryPath, branchName: branchName,
        pullRequestURL: pr.url, pullRequestHeadSHA: head, archivedAt: Date()))
    }
    return records
  }
}

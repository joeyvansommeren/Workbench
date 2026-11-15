import AgentHubGitHub
import Foundation

/// A one-shot consumer of the shared, repository-aware observer. No new poller.
enum FinishGitHubSnapshotReader {
  static func matches(_ snapshot: GitHubPRObservationSnapshot, path: String, branch: String) -> Bool {
    guard case .session(let projectPath, let branchName, _) = snapshot.target else { return false }
    return WorktreeModuleResolver.normalizedDirectoryPath(projectPath)
      == WorktreeModuleResolver.normalizedDirectoryPath(path) && branchName == branch
  }

  static func read(
    service: any GitHubPRObservationServiceProtocol,
    path: String,
    branch: String,
    links: [GitHubPullRequestURLReference] = []
  ) async -> GitHubPRObservationSnapshot? {
    let target = GitHubPRObservationTarget.session(projectPath: path, branchName: branch, linkedPullRequests: links)
    await service.refresh(target)
    let subscription = await service.subscribe(to: target, refreshOnSubscribe: false)
    var result: GitHubPRObservationSnapshot?
    for await snapshot in subscription.updates {
      result = snapshot
      break
    }
    await service.unsubscribe(subscriptionID: subscription.id)
    return result?.target == target ? result : nil
  }
}

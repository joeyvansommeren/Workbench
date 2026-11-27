import AgentHubGitDiff
import AgentHubGitHub
import SwiftUI

enum SessionPublicationSuggestion: Equatable {
  case reviewChanges, reviewCommit, create, open, feedback, checks, checkPublication

  var title: String {
    switch self {
    case .reviewChanges: "Review changes"
    case .reviewCommit: "Review commit"
    case .create: "Create PR…"
    case .checkPublication: "Check draft on GitHub"
    case .open: "Open PR"
    case .feedback: "Address feedback"
    case .checks: "View failed checks"
    }
  }

  var icon: String {
    switch self {
    case .reviewChanges: "doc.text.magnifyingglass"
    case .reviewCommit: "checkmark.seal"
    case .create, .open: "arrow.triangle.pull"
    case .checkPublication: "arrow.clockwise"
    case .feedback: "text.bubble"
    case .checks: "exclamationmark.circle"
    }
  }

  func browserURL(for request: GitHubPullRequest?) -> URL? {
    guard self == .open || self == .checks, let request,
      let url = URL(string: request.url), url.scheme == "https",
      GitHubPullRequestURLReference(urlString: request.url) != nil
    else { return nil }
    return self == .checks ? url.appendingPathComponent("checks") : url
  }

  static func make(
    progress: SessionProgressPresentation, diff: LocalDiffSummary?,
    snapshot: GitHubPRObservationSnapshot?, projectPath: String, branch: String?,
    hasPublicationRepository: Bool = true, awaitsGitHub: Bool = false
  ) -> Self? {
    if awaitsGitHub { return .checkPublication }
    switch progress.action {
    case .starting, .working, .answer, .permission:
      return nil
    default: break
    }
    guard let branch, !branch.isEmpty else { return nil }
    if let snapshot, snapshot.state == .ready, !snapshot.isStale,
      case .session(let path, let observedBranch, _) = snapshot.target,
      WorktreeModuleResolver.normalizedDirectoryPath(path)
        == WorktreeModuleResolver.normalizedDirectoryPath(projectPath),
      observedBranch?.utf8.elementsEqual(branch.utf8) == true
    {
      if let pr = snapshot.pullRequest, pr.headRefName.utf8.elementsEqual(branch.utf8) {
        if pr.stateKind == .open {
          if snapshot.ciSummary.overallStatus == .failure { return .checks }
          if pr.reviewDecision?.uppercased() == "CHANGES_REQUESTED" { return .feedback }
        }
        return .open
      }
      if snapshot.pullRequest == nil {
        if progress.action == .reviewChanges { return .reviewChanges }
        if diff?.hasUncommittedChanges == true { return .reviewCommit }
        if hasPublicationRepository, let diff, diff.hasUncommittedChanges == false, diff.fileCount > 0 {
          return .create
        }
      }
    }
    return progress.action == .reviewChanges ? .reviewChanges : nil
  }
}

struct SessionPublicationButton: View {
  let suggestion: SessionPublicationSuggestion
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ViewThatFits(in: .horizontal) {
        Label(suggestion.title, systemImage: suggestion.icon).fixedSize()
        Image(systemName: suggestion.icon)
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .lineLimit(1)
    .help(suggestion.title)
    .accessibilityLabel(suggestion.title)
    .accessibilityIdentifier("session.publicationAction")
  }
}

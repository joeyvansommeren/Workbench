//
//  PullRequestRowPresentation.swift
//  AgentHub
//
//  Pure text and state for a pull request in the new shell's Reviews list and
//  detail: age, `repo #number`, author and the CI checks state. No SwiftUI.
//

import AgentHubGitHub
import Foundation

/// The CI state a row shows as an icon. Nil (no icon) when there are no
/// checks or the state is not known yet.
enum PullRequestChecksState: Equatable, Sendable {
  case pass
  case fail
  case pending

  init?(_ status: CIStatus?) {
    // `CIStatus.none` clashes with `Optional.none`, so match `.some` explicitly.
    switch status {
    case .some(.success): self = .pass
    case .some(.failure): self = .fail
    case .some(.pending): self = .pending
    case .some(.none), nil: return nil
    }
  }

  var systemImage: String {
    switch self {
    case .pass: return "checkmark.circle"
    case .fail: return "xmark.circle"
    case .pending: return "clock"
    }
  }

  /// Sort rank, shared by the table and the detail's checks list: failing
  /// first, then pending, passed, and unknown (nil) last.
  static func sortRank(_ state: PullRequestChecksState?) -> Int {
    switch state {
    case .fail: return 0
    case .pending: return 1
    case .pass: return 2
    case nil: return 3
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .pass: return "Checks passed"
    case .fail: return "Checks failed"
    case .pending: return "Checks pending"
    }
  }
}

struct PullRequestRowPresentation: Equatable {
  let id: String
  let title: String
  let age: String
  /// `xfa-dashboard #1843`, shown in mono.
  let repositoryLabel: String
  let author: String
  let checks: PullRequestChecksState?

  init(pullRequest: GitHubProjectPullRequest, checks: CIStatus?, now: Date = Date()) {
    id = pullRequest.id
    title = pullRequest.title
    age = Self.age(from: pullRequest.updatedAt, now: now)
    repositoryLabel = "\(pullRequest.repositoryName) #\(pullRequest.number)"
    author = pullRequest.authorLogin ?? "unknown"
    self.checks = PullRequestChecksState(checks)
  }

  /// Compact age as in the prototype: `now`, `12m`, `5h`, `2d`, `3w`, `1y`.
  static func age(from date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let seconds = max(0, now.timeIntervalSince(date))
    let minute: Double = 60
    let hour = 60 * minute
    let day = 24 * hour
    switch seconds {
    case ..<minute: return "now"
    case ..<hour: return "\(Int(seconds / minute))m"
    case ..<day: return "\(Int(seconds / hour))h"
    case ..<(7 * day): return "\(Int(seconds / day))d"
    case ..<(365 * day): return "\(Int(seconds / (7 * day)))w"
    default: return "\(Int(seconds / (365 * day)))y"
    }
  }
}

/// The Checks value in the detail's property card: `14 passed`, `2 failed`,
/// `3 pending`, `2 skipped` or `No checks`. The state follows GitHub's rollup
/// (`CIStatus.rollup`), the same rule as the queue row's icon, so skipped and
/// neutral checks count as passing.
struct PullRequestChecksSummary: Equatable {
  let text: String
  let state: PullRequestChecksState?

  init(checks: [GitHubCheckRun]?) {
    let runs = checks ?? []
    state = PullRequestChecksState(CIStatus.rollup(of: runs))
    let failed = runs.filter { $0.ciStatus == .failure }.count
    let pending = runs.filter { $0.ciStatus == .pending }.count
    let passed = runs.filter { $0.ciStatus == .success }.count
    if failed > 0 {
      text = "\(failed) failed"
    } else if pending > 0 {
      text = "\(pending) pending"
    } else if passed > 0 {
      text = "\(passed) passed"
    } else if !runs.isEmpty {
      text = "\(runs.count) skipped"
    } else {
      text = "No checks"
    }
  }
}

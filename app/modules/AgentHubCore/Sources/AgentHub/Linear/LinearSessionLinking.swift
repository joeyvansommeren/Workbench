//
//  LinearSessionLinking.swift
//  AgentHub
//
//  Links agent sessions to Linear issues by the issue identifier they carry:
//  the branch name (`wb-12-fix-login`), a Linear URL or "Linear issue ID" in
//  the first prompt, or a custom name that starts with the identifier.
//
//  Must not collide with Jira: a key like `WB-12` is only treated as Linear
//  when its prefix matches a known Linear team key.
//

import Foundation

enum LinearIssueKeyDetector {
  private static let linearURLPattern = try! NSRegularExpression(
    pattern: #"linear\.app/[^/]+/issue/([A-Za-z][A-Za-z0-9]+-\d+)"#
  )
  private static let explicitPromptPattern = try! NSRegularExpression(
    pattern: #"Linear issue ([A-Z][A-Z0-9]+-\d+)"#
  )
  private static let prefixedKey = try! NSRegularExpression(
    pattern: #"^([A-Za-z][A-Za-z0-9]+-\d+)(?:$|[-_ :])"#
  )

  /// Issue identifiers for a session. Linear URLs and the "Linear issue KEY"
  /// prompt always count. Branch and name prefixes only count when their prefix
  /// matches a known Linear team key AND does not match a known Jira project key.
  static func keys(
    branchName: String?,
    customName: String?,
    prompt: String?,
    knownLinearTeamKeys: Set<String>,
    knownJiraProjectKeys: Set<String>
  ) -> [String] {
    var keys: [String] = []
    func add(_ key: String) {
      let key = key.uppercased()
      if !keys.contains(key) { keys.append(key) }
    }

    // Explicit references in prompts.
    if let prompt {
      let text = String(prompt.prefix(4000))
      let range = NSRange(text.startIndex..., in: text)
      for match in linearURLPattern.matches(in: text, range: range) {
        if let keyRange = Range(match.range(at: 1), in: text) { add(String(text[keyRange])) }
      }
      for match in explicitPromptPattern.matches(in: text, range: range) {
        if let keyRange = Range(match.range(at: 1), in: text) { add(String(text[keyRange])) }
      }
    }

    // Branch name and custom name: only for known Linear team keys.
    let candidates = [
      branchName.map { String($0.split(separator: "/").last ?? "") },
      customName,
    ].compactMap { $0 }
    for candidate in candidates {
      let range = NSRange(candidate.startIndex..., in: candidate)
      guard
        let match = prefixedKey.firstMatch(in: candidate, range: range),
        let keyRange = Range(match.range(at: 1), in: candidate)
      else { continue }
      let key = String(candidate[keyRange]).uppercased()
      guard let project = key.split(separator: "-").first.map(String.init) else { continue }
      // Only Linear if the prefix is a known Linear team key, and not also a
      // known Jira project key (avoids collision when both use the same prefix).
      if knownLinearTeamKeys.contains(project) && !knownJiraProjectKeys.contains(project) {
        add(key)
      }
    }
    return keys
  }
}

/// A session (or a session still launching) that works on a Linear issue.
struct LinearLinkedSession: Identifiable, Equatable {
  let provider: SessionProviderKind
  let itemID: String
  let title: String
  let branchName: String?
  let lastActivityAt: Date
  let isPending: Bool
  let isMonitored: Bool
  let session: CLISession?

  var id: String { itemID }
}

/// Builds issue identifier -> sessions for the Linear board. Cached per session
/// input so re-rendering the board doesn't re-run regexes.
@MainActor
final class LinearSessionLinker {
  private var cache: [String: [String]] = [:]

  func links(
    from viewModels: [CLISessionsViewModel],
    knownLinearTeamKeys: Set<String>,
    knownJiraProjectKeys: Set<String>
  ) -> [String: [LinearLinkedSession]] {
    var result: [String: [LinearLinkedSession]] = [:]
    var seen: Set<String> = []

    for viewModel in viewModels {
      let provider = viewModel.providerKind
      let monitored = viewModel.monitoredSessionList
      let monitoredIDs = Set(monitored.map(\.id))
      let sessions =
        monitored
        + viewModel.selectedRepositories.flatMap(\.worktrees).flatMap(\.sessions)

      for session in sessions {
        let itemID = SidebarSessionItemID.monitored(provider: provider, sessionId: session.id)
        guard seen.insert(itemID).inserted else { continue }
        let customName = viewModel.sessionCustomNames[session.id]
        let keys = cachedKeys(
          id: itemID,
          branchName: session.branchName,
          customName: customName,
          prompt: session.firstMessage,
          knownLinearTeamKeys: knownLinearTeamKeys,
          knownJiraProjectKeys: knownJiraProjectKeys
        )
        guard !keys.isEmpty else { continue }
        let link = LinearLinkedSession(
          provider: provider,
          itemID: itemID,
          title: customName ?? session.slug ?? session.firstMessage ?? session.shortId,
          branchName: session.branchName,
          lastActivityAt: session.lastActivityAt,
          isPending: false,
          isMonitored: monitoredIDs.contains(session.id),
          session: session
        )
        for key in keys { result[key, default: []].append(link) }
      }

      for pending in viewModel.pendingHubSessions {
        let itemID = SidebarSessionItemID.pending(provider: provider, pendingId: pending.id)
        let keys = cachedKeys(
          id: itemID,
          branchName: nil,
          customName: nil,
          prompt: pending.initialPrompt,
          knownLinearTeamKeys: knownLinearTeamKeys,
          knownJiraProjectKeys: knownJiraProjectKeys
        )
        for key in keys {
          result[key, default: []].append(
            LinearLinkedSession(
              provider: provider,
              itemID: itemID,
              title: "Starting \(provider.rawValue)\u{2026}",
              branchName: nil,
              lastActivityAt: pending.startedAt,
              isPending: true,
              isMonitored: true,
              session: nil
            ))
        }
      }
    }
    return result.mapValues { $0.sorted { $0.lastActivityAt > $1.lastActivityAt } }
  }

  func cachedKeys(
    id: String,
    branchName: String?,
    customName: String?,
    prompt: String?,
    knownLinearTeamKeys: Set<String>,
    knownJiraProjectKeys: Set<String>
  ) -> [String] {
    let cacheKey = [
      id, branchName ?? "", customName ?? "", String(prompt?.count ?? 0),
      knownLinearTeamKeys.sorted().joined(separator: ","),
      knownJiraProjectKeys.sorted().joined(separator: ","),
    ].joined(separator: "|")
    if let cached = cache[cacheKey] { return cached }
    let keys = LinearIssueKeyDetector.keys(
      branchName: branchName,
      customName: customName,
      prompt: prompt,
      knownLinearTeamKeys: knownLinearTeamKeys,
      knownJiraProjectKeys: knownJiraProjectKeys
    )
    cache[cacheKey] = keys
    return keys
  }
}

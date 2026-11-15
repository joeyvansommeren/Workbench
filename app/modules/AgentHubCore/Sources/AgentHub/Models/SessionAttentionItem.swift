import Foundation

struct SessionAttentionInput: Equatable {
  let id: String
  let title: String
  let provider: SessionProviderKind
  let sessionID: String
  let projectPath: String
  let status: SessionStatus?
  let isPending: Bool
  let pendingToolName: String?
  var lastActivityAt: Date? = nil
  var branchName: String? = nil
}

enum SessionAttentionCategory: Equatable {
  case other
  case checks
}

struct SessionAttentionItem: Equatable, Identifiable {
  let id: String
  let title: String
  let reason: String
  var category: SessionAttentionCategory = .other
}

enum SessionAttentionProjection {
  static func project(inputs: [SessionAttentionInput], records: [String: SessionResult],
    failedChecks: [String: String], previous: [SessionAttentionItem]) -> [SessionAttentionItem] {
    var candidates: [String: SessionAttentionItem] = [:]
    for input in inputs where !input.isPending {
      var reason: String?
      var category: SessionAttentionCategory = .other
      if case .awaitingApproval(let tool) = input.status {
        reason = SessionInteractiveInputTool.matches(tool) ? "Answer a question" : "Review a permission request"
      } else if let tool = input.pendingToolName, !SessionInteractiveInputTool.matches(tool) {
        reason = "Review a permission request"
      } else if let failure = failedChecks[input.id] {
        reason = failure
        category = .checks
      } else if let result = records[input.id], result.matches(projectPath: input.projectPath) {
        if result.decision == .none { reason = "Inspect the recorded result" }
        else if result.decision == .accepted, let activity = input.lastActivityAt,
          activity > (result.decidedAt ?? result.updatedAt) {
          reason = "New activity after acceptance · review result"
        }
      }
      if let reason { candidates[input.id] = SessionAttentionItem(id: input.id, title: input.title, reason: reason, category: category) }
    }
    let retained = previous.compactMap { candidates.removeValue(forKey: $0.id) }
    return retained + candidates.values.sorted { $0.id < $1.id }
  }

  static func next(after id: String?, in items: [SessionAttentionItem]) -> SessionAttentionItem? {
    guard !items.isEmpty else { return nil }
    guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return items.first }
    return items[(index + 1) % items.count]
  }
}

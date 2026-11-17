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
  case permission
  case question
  case result
  case checks
}

struct SessionAttentionItem: Equatable, Identifiable {
  let id: String
  let title: String
  let reason: String
  var category: SessionAttentionCategory = .other

  var accessibilityLabel: String { "\(title), \(reason)" }
}

enum SessionAttentionProjection {
  static func project(
    inputs: [SessionAttentionInput], records: [String: SessionResult],
    failedChecks: [String: String], previous: [SessionAttentionItem]
  ) -> [SessionAttentionItem] {
    var candidates: [String: SessionAttentionItem] = [:]
    for input in inputs where !input.isPending {
      var reason: String?
      var category: SessionAttentionCategory = .other
      if case .awaitingApproval(let tool) = input.status {
        let isQuestion = SessionInteractiveInputTool.matches(tool)
        reason = isQuestion ? "Answer a question" : "Permission needed · \(tool)"
        category = isQuestion ? .question : .permission
      } else if let tool = input.pendingToolName {
        let isQuestion = SessionInteractiveInputTool.matches(tool)
        reason = isQuestion ? "Answer a question" : "Permission needed · \(tool)"
        category = isQuestion ? .question : .permission
      } else if let failure = failedChecks[input.id] {
        reason = failure
        category = .checks
      } else if SessionStatusPresentation(status: input.status).activity != .running {
        category = .result
        reason = resultReason(
          result: records[input.id], projectPath: input.projectPath, activity: input.lastActivityAt)
      }
      if let reason {
        candidates[input.id] = SessionAttentionItem(
          id: input.id, title: input.title, reason: reason, category: category)
      }
    }
    let retained = previous.compactMap { candidates.removeValue(forKey: $0.id) }
    return retained + candidates.values.sorted { $0.id < $1.id }
  }

  static func resultReason(result: SessionResult?, projectPath: String, activity: Date?) -> String?
  {
    guard let result, result.matches(projectPath: projectPath) else { return nil }
    if result.decision == .none { return "Inspect the recorded result" }
    // Activity alone is not a new result. Revising a result explicitly resets its decision.
    return nil
  }

  static func next(after id: String?, in items: [SessionAttentionItem], forward: Bool = true)
    -> SessionAttentionItem?
  {
    guard !items.isEmpty else { return nil }
    guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return items.first }
    return items[(index + (forward ? 1 : items.count - 1)) % items.count]
  }
}

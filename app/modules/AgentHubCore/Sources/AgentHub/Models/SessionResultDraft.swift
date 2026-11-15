import Foundation

/// Reuses observed content without inferring product intent or declaring the work complete.
enum SessionResultDraft {
  static func make(provider: SessionProviderKind, sessionID: String, projectPath: String,
    state: SessionMonitorState?, recipe: ProjectLaunchRecipe?) -> SessionResult {
    var result = SessionResult(provider: provider, sessionID: sessionID, projectPath: projectPath)
    result.summary = state?.lastAssistantMessage ?? ""
    let paths = state?.recentActivities.compactMap { $0.toolInput?.filePath } ?? []
    result.affectedTargets = Array(Set(paths)).sorted().joined(separator: "\n")
    result.destination = state?.detectedLocalhostURL?.absoluteString ?? recipe?.destination ?? ""
    result.expectedState = recipe?.expectedState ?? ""
    return result
  }
}

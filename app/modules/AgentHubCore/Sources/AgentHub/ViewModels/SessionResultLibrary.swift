import Foundation

@MainActor
@Observable
final class SessionResultLibrary {
  private(set) var records: [String: SessionResult] = [:]
  private(set) var loadError: String?
  private(set) var isLoaded = false
  private(set) var isLoading = false
  private let store: (any SessionResultStoreProtocol)?

  init(store: (any SessionResultStoreProtocol)?) { self.store = store }

  func load() async {
    guard !isLoaded, !isLoading else { return }
    guard let store else { loadError = ResultLaunchError.unavailableStore.localizedDescription; return }
    isLoading = true
    defer { isLoading = false }
    do {
      let results = try await store.loadSessionResults()
      records.merge(Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })) { current, _ in current }
      isLoaded = true
      loadError = nil
    } catch { loadError = error.localizedDescription }
  }

  func save(_ result: SessionResult, recipe: ProjectLaunchRecipe? = nil) async throws {
    guard let store else { throw ResultLaunchError.unavailableStore }
    if let recipe {
      guard let atomicStore = store as? any SessionResultRecipeStoreProtocol else {
        throw ResultLaunchError.unavailableStore
      }
      try await atomicStore.saveSessionResult(result, recipe: recipe)
    } else {
      try await store.saveSessionResult(result)
    }
    records[result.id] = result
  }
}

import Foundation

@MainActor
@Observable
final class SessionResultLibrary {
  private(set) var records: [String: SessionResult] = [:]
  private(set) var loadError: String?
  private var loaded = false
  private let store: (any SessionResultStoreProtocol)?

  init(store: (any SessionResultStoreProtocol)?) { self.store = store }

  func load() async {
    guard !loaded else { return }
    guard let store else { loadError = ResultLaunchError.unavailableStore.localizedDescription; return }
    do {
      let results = try await store.loadSessionResults()
      records.merge(Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })) { current, _ in current }
      loaded = true
      loadError = nil
    } catch { loadError = error.localizedDescription }
  }

  func save(_ result: SessionResult) async throws {
    guard let store else { throw ResultLaunchError.unavailableStore }
    try await store.saveSessionResult(result)
    records[result.id] = result
  }
}

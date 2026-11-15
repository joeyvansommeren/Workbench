import Foundation

struct SessionReadCursor: Equatable, Sendable {
  let provider: SessionProviderKind
  let sessionID: String
  let activity: Date
  var key: SessionReadCursorKey { .init(provider: provider, sessionID: sessionID) }
}

struct SessionReadCursorKey: Hashable, Sendable {
  let provider: SessionProviderKind
  let sessionID: String
}

protocol SessionReadCursorStoreProtocol: Sendable {
  func loadReadCursors() async throws -> [SessionReadCursor]
  func acknowledgeReadCursor(_ cursor: SessionReadCursor) async throws
}

@MainActor
@Observable
final class SessionReadCursorModel {
  enum LoadState { case pending, loaded, failed }
  private let store: (any SessionReadCursorStoreProtocol)?
  private(set) var state: LoadState = .pending
  private var cursors: [SessionReadCursorKey: Date] = [:]
  private var durable: [SessionReadCursorKey: Date] = [:]
  private var inFlight: Set<SessionReadCursorKey> = []
  private var loading = false

  init(store: (any SessionReadCursorStoreProtocol)?) { self.store = store }

  func load() async {
    guard state != .loaded, !loading else { return }
    guard let store else {
      state = .failed
      return
    }
    loading = true
    defer { loading = false }
    do {
      for cursor in try await store.loadReadCursors() {
        durable[cursor.key] = max(durable[cursor.key] ?? .distantPast, cursor.activity)
        cursors[cursor.key] = max(cursors[cursor.key] ?? .distantPast, cursor.activity)
      }
      state = .loaded
    } catch { state = .failed }
  }

  func isUnread(provider: SessionProviderKind, sessionID: String, activity: Date?) -> Bool {
    guard state == .loaded, let activity else { return false }
    return activity > (cursors[.init(provider: provider, sessionID: sessionID)] ?? .distantPast)
  }

  func acknowledge(provider: SessionProviderKind, sessionID: String, activity: Date) async {
    let key = SessionReadCursorKey(provider: provider, sessionID: sessionID)
    cursors[key] = max(cursors[key] ?? .distantPast, activity)
    guard let store, !inFlight.contains(key) else { return }
    inFlight.insert(key)
    defer { inFlight.remove(key) }
    while let latest = cursors[key], latest > (durable[key] ?? .distantPast) {
      do {
        try await store.acknowledgeReadCursor(
          .init(provider: provider, sessionID: sessionID, activity: latest))
        durable[key] = max(durable[key] ?? .distantPast, latest)
      } catch { return }
    }
  }
}

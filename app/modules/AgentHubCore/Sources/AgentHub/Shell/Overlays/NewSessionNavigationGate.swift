import Foundation
import Observation

/// A late launch may not change a newer sheet or another window.
@MainActor
@Observable
final class NewSessionNavigationGate {
  private(set) var requestID: UUID?

  func begin(_ id: UUID) { requestID = id }
  func cancel(_ id: UUID) {
    if requestID == id { requestID = nil }
  }
  func complete(_ id: UUID) -> Bool {
    guard requestID == id else { return false }
    requestID = nil
    return true
  }
}

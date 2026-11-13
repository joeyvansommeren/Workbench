import Foundation

public enum LinearAPIError: Error, Equatable, Sendable {
  /// No API key found in the Keychain.
  case missingKey
  /// Linear returned 401 — the key is invalid or revoked.
  case unauthorized
  /// Linear returned 429 — slow down.
  case rateLimited
  /// A network-level failure (no response, DNS, timeout).
  case network(String)
  /// The response could not be decoded.
  case decoding(String)
  /// GraphQL returned user-level errors.
  case graphQL([String])
}

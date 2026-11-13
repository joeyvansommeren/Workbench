//
//  CLIAvailabilityService.swift
//  AgentHub
//
//  Checks whether a provider CLI (claude / codex) is installed and reachable.
//

import Foundation

/// Checks whether a provider's CLI executable can be found on disk.
///
/// Implementations may cache the result; call ``checkAvailability`` to force
/// a fresh lookup (e.g. when the user opens New Session).
public protocol CLIAvailabilityChecking: Sendable {
  /// Returns `true` when the executable for `provider` is reachable.
  /// Uses a cached result when available — call ``checkAvailability``
  /// first when a fresh answer is needed.
  func isAvailable(for provider: SessionProviderKind) -> Bool

  /// Forces a fresh PATH / filesystem lookup and updates the cache.
  @discardableResult
  func checkAvailability(for provider: SessionProviderKind) -> Bool

  /// Convenience: refreshes both providers and returns the results.
  @discardableResult
  func checkAll() -> [SessionProviderKind: Bool]
}

/// Production implementation that delegates to `TerminalLauncher` for the
/// actual filesystem / `which` lookup. Results are cached in memory so
/// repeated reads from the UI are cheap; call `checkAvailability` to refresh.
public final class CLIAvailabilityService: CLIAvailabilityChecking, @unchecked Sendable {
  private let lock = NSLock()
  private var cache: [SessionProviderKind: Bool] = [:]
  private let claudeConfiguration: CLICommandConfiguration
  private let codexConfiguration: CLICommandConfiguration
  /// Injectable lookup closure — tests replace this with a mock.
  private let findExecutable: @Sendable (String, SessionProviderKind, [String]) -> String?

  public convenience init(
    claudeConfiguration: CLICommandConfiguration = .claudeDefault,
    codexConfiguration: CLICommandConfiguration = .codexDefault
  ) {
    self.init(
      claudeConfiguration: claudeConfiguration,
      codexConfiguration: codexConfiguration,
      findExecutable: { command, provider, additionalPaths in
        switch provider {
        case .claude:
          return TerminalLauncher.findClaudeExecutable(
            command: command,
            additionalPaths: additionalPaths
          )
        case .codex:
          return TerminalLauncher.findCodexExecutable(
            command: command,
            additionalPaths: additionalPaths
          )
        }
      }
    )
  }

  /// Designated initializer — allows injecting the lookup for tests.
  public init(
    claudeConfiguration: CLICommandConfiguration = .claudeDefault,
    codexConfiguration: CLICommandConfiguration = .codexDefault,
    findExecutable: @escaping @Sendable (String, SessionProviderKind, [String]) -> String?
  ) {
    self.claudeConfiguration = claudeConfiguration
    self.codexConfiguration = codexConfiguration
    self.findExecutable = findExecutable
  }

  public func isAvailable(for provider: SessionProviderKind) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if let cached = cache[provider] {
      return cached
    }
    // No cached value yet — do a synchronous check.
    let result = performCheck(for: provider)
    cache[provider] = result
    return result
  }

  @discardableResult
  public func checkAvailability(for provider: SessionProviderKind) -> Bool {
    let result = performCheck(for: provider)
    lock.lock()
    cache[provider] = result
    lock.unlock()
    return result
  }

  @discardableResult
  public func checkAll() -> [SessionProviderKind: Bool] {
    var results: [SessionProviderKind: Bool] = [:]
    for provider in SessionProviderKind.allCases {
      results[provider] = checkAvailability(for: provider)
    }
    return results
  }

  private func performCheck(for provider: SessionProviderKind) -> Bool {
    let config = provider == .claude ? claudeConfiguration : codexConfiguration
    return findExecutable(config.executableName, provider, config.additionalPaths) != nil
  }
}

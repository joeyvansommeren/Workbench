import Foundation
import Testing

@testable import AgentHubCore

@Suite("Apple shell launch flag")
struct AppleShellLaunchFlagTests {
  private let key = AgentHubDefaults.appleShellEnabled

  /// A throwaway defaults suite, so no test touches the real preferences.
  private func makeDefaults() -> (UserDefaults, String) {
    let suiteName = "AppleShellLaunchFlagTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }

  @Test("Unset means the new interface")
  func unsetIsOn() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(AppleShellLaunchFlag.resolve(in: defaults))
  }

  @Test("A saved NO gives the legacy interface, a saved YES the new one")
  func savedValueWins() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: key)
    #expect(!AppleShellLaunchFlag.resolve(in: defaults))
    defaults.set(true, forKey: key)
    #expect(AppleShellLaunchFlag.resolve(in: defaults))
  }

  @Test("The launch argument wins over the saved value")
  func launchArgumentWins() {
    let (defaults, suiteName) = makeDefaults()
    defer {
      defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
      defaults.removePersistentDomain(forName: suiteName)
    }
    // `-com.agenthub.features.appleShell NO` lands in the argument domain as the string "NO".
    defaults.set(true, forKey: key)
    defaults.setVolatileDomain([key: "NO"], forName: UserDefaults.argumentDomain)
    #expect(!AppleShellLaunchFlag.resolve(in: defaults))

    defaults.set(false, forKey: key)
    defaults.setVolatileDomain([key: "YES"], forName: UserDefaults.argumentDomain)
    #expect(AppleShellLaunchFlag.resolve(in: defaults))
  }
}

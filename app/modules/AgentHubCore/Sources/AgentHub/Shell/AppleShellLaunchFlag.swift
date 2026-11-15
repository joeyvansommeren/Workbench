//
//  AppleShellLaunchFlag.swift
//  AgentHub
//
//  The value of `AgentHubDefaults.appleShellEnabled` for this process.
//  `AgentHubApp.init` reads it first, so it is captured at launch and later
//  toggles in Settings do not change it until relaunch.
//

import Foundation

public enum AppleShellLaunchFlag {
  /// The launch argument `-com.agenthub.features.appleShell YES|NO` overrides
  /// the stored value (UserDefaults argument domain).
  public static let isEnabled: Bool = resolve(in: .standard)

  /// The new interface is the default since P11a: unset means on. Only an
  /// explicit NO (Settings or the launch argument) gives the legacy UI.
  static func resolve(in defaults: UserDefaults) -> Bool {
    guard defaults.object(forKey: AgentHubDefaults.appleShellEnabled) != nil else {
      return true
    }
    // `bool(forKey:)`, not `as? Bool`: the argument domain stores "NO" as a string.
    return defaults.bool(forKey: AgentHubDefaults.appleShellEnabled)
  }
}

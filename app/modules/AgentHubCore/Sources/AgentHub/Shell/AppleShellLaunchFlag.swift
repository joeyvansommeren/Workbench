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
  public static let isEnabled: Bool =
    UserDefaults.standard.bool(forKey: AgentHubDefaults.appleShellEnabled)
}

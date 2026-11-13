//
//  AppearancePreference.swift
//  AgentHub
//
//  User's preferred appearance: System, Light or Dark.
//  Stored in `AgentHubDefaults.appearance` as a raw value.
//  Not wired into the UI yet — that happens in P4/P10.
//

import AppKit

/// The three appearance choices offered by the new shell.
public enum AppearancePreference: String, CaseIterable, Sendable, Identifiable {
  case system
  case light
  case dark

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .system: return "System"
    case .light:  return "Light"
    case .dark:   return "Dark"
    }
  }

  /// Map to an `NSAppearance.Name` for `NSApp.appearance`.
  /// `nil` means follow the system setting.
  public var nsAppearanceName: NSAppearance.Name? {
    switch self {
    case .system: return nil
    case .light:  return .aqua
    case .dark:   return .darkAqua
    }
  }

  /// Read from UserDefaults, defaulting to `.system`.
  public static func fromDefaults() -> AppearancePreference {
    let raw = UserDefaults.standard.string(forKey: AgentHubDefaults.appearance) ?? "system"
    return AppearancePreference(rawValue: raw) ?? .system
  }

  /// Write to UserDefaults.
  public func saveToDefaults() {
    UserDefaults.standard.set(rawValue, forKey: AgentHubDefaults.appearance)
  }
}

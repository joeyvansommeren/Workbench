//
//  WorkbenchTheme.swift
//  AgentHub
//
//  A theme pairs light and dark palettes with a typography family.
//  `WorkbenchThemeRegistry` is the runtime source of truth for the
//  active theme in the new shell.
//

import AppKit
import Combine
import Foundation

// MARK: - Theme

/// A named pair of light and dark palettes plus a typography family.
public struct WorkbenchTheme: Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let light: WorkbenchPalette
  public let dark: WorkbenchPalette
  public let typography: WorkbenchTypography.Family

  public init(
    id: String,
    name: String,
    light: WorkbenchPalette,
    dark: WorkbenchPalette,
    typography: WorkbenchTypography.Family
  ) {
    self.id = id
    self.name = name
    self.light = light
    self.dark = dark
    self.typography = typography
  }
}

// MARK: - Built-in themes

extension WorkbenchTheme {
  /// The default Apple-style theme (Standard palette).
  public static let apple = WorkbenchTheme(
    id: "apple",
    name: "Standard",
    light: .appleLight,
    dark: .appleDark,
    typography: .interDisplay
  )

  /// Warm variant of the Apple theme.
  public static let appleWarm = WorkbenchTheme(
    id: "appleWarm",
    name: "Warm",
    light: .appleWarmLight,
    dark: .appleWarmDark,
    typography: .interDisplay
  )

  /// All available themes, for settings UI.
  public static let allBuiltIn: [WorkbenchTheme] = [.apple, .appleWarm]
}

// MARK: - Palette preference

/// Which colour palette the user prefers.
public enum PalettePreference: String, CaseIterable, Sendable, Identifiable {
  case standard
  case warm

  /// The palette used when nothing is saved. Every reader of
  /// `AgentHubDefaults.palette` falls back to this, so they agree.
  public static let defaultPalette: PalettePreference = .warm

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .standard: return "Standard"
    case .warm:     return "Warm"
    }
  }

  /// The `WorkbenchTheme` this preference resolves to.
  public var theme: WorkbenchTheme {
    switch self {
    case .standard: return .apple
    case .warm:     return .appleWarm
    }
  }

  /// Read from UserDefaults, defaulting to `defaultPalette`.
  public static func fromDefaults() -> PalettePreference {
    UserDefaults.standard.string(forKey: AgentHubDefaults.palette)
      .flatMap(PalettePreference.init(rawValue:)) ?? defaultPalette
  }

  /// Write to UserDefaults.
  public func saveToDefaults() {
    UserDefaults.standard.set(rawValue, forKey: AgentHubDefaults.palette)
  }
}

// MARK: - Registry

/// Runtime registry for the active theme. The new shell reads from here;
/// the legacy shell ignores it entirely.
///
/// ## Live switch
///
/// When the palette changes, the registry:
/// 1. Replaces `current` with the new theme.
/// 2. Invalidates the dynamic `NSColor` cache so tokens resolve fresh.
/// 3. Bumps `revision`, an observable counter that SwiftUI views can
///    read (via `.wbRedrawsOnPaletteChange()` / `.id(registry.revision)`)
///    to redraw.
/// 4. Re-applies `NSApp.appearance` for the explicit light/dark case.
///    The appearance toggle alone does not redraw SwiftUI colour tokens;
///    views must also observe `revision` via `.wbRedrawsOnPaletteChange()`.
///
/// The mechanism is in place now. A settings UI or test can call
/// `setPalette(_:)` and windows redraw immediately.
@MainActor
@Observable
public final class WorkbenchThemeRegistry {
  public static let shared = WorkbenchThemeRegistry()
  private init() {
    // Resolve from stored preference at launch.
    current = PalettePreference.fromDefaults().theme
  }

  /// The active theme.
  public private(set) var current: WorkbenchTheme

  /// A monotonically increasing counter, bumped on every theme change.
  /// Views that cache colour can observe this.
  public private(set) var revision: Int = 0

  /// Switch the active palette. Persists the preference and forces a
  /// full redraw of all windows — no relaunch needed.
  public func setPalette(_ preference: PalettePreference) {
    preference.saveToDefaults()
    let newTheme = preference.theme
    guard current != newTheme else { return }
    current = newTheme

    // Invalidate the dynamic NSColor cache.
    WorkbenchColorCache.shared.invalidate()

    // Bump revision so observable SwiftUI dependents redraw.
    revision += 1

    // Re-apply NSApp.appearance for the explicit light/dark case.
    // This does not redraw SwiftUI colour tokens on its own;
    // views must also observe `revision` via `.wbRedrawsOnPaletteChange()`.
    // NSApp is nil outside a running app (unit tests), so guard instead of unwrapping.
    guard let app = NSApp else { return }
    let saved = app.appearance
    app.appearance = nil
    app.appearance = saved
  }

  /// Replace the active theme directly (for tests or advanced use).
  public func setCurrent(_ theme: WorkbenchTheme) {
    guard current != theme else { return }
    current = theme
    WorkbenchColorCache.shared.invalidate()
    revision += 1
  }

  /// Resolve the palette for the given appearance.
  public func palette(dark: Bool) -> WorkbenchPalette {
    dark ? current.dark : current.light
  }
}

//
//  WorkbenchAppearanceController.swift
//  AgentHub
//
//  Applies the new shell's Appearance (System / Light / Dark) and Palette
//  (Standard / Warm) settings live. Appearance goes to `NSApp.appearance`;
//  palette goes through `WorkbenchThemeRegistry`, whose revision redraws every
//  root that applies `.wbRedrawsOnPaletteChange()`.
//
//  Only the new shell calls this. The legacy shell keeps following the system
//  and its YAML theme.
//

import AppKit

/// Something whose appearance can be set: `NSApplication` in the app, a fake
/// in tests (so tests never change the test host's appearance).
@MainActor
protocol AppearanceApplying: AnyObject {
  var appearance: NSAppearance? { get set }
}

extension NSApplication: AppearanceApplying {}

@MainActor
enum WorkbenchAppearanceController {
  /// The appearance to apply; nil follows the system.
  static func appearance(for preference: AppearancePreference) -> NSAppearance? {
    preference.nsAppearanceName.flatMap(NSAppearance.init(named:))
  }

  static func storedAppearance(defaults: UserDefaults = .standard) -> AppearancePreference {
    defaults.string(forKey: AgentHubDefaults.appearance)
      .flatMap(AppearancePreference.init(rawValue:)) ?? .system
  }

  static func storedPalette(defaults: UserDefaults = .standard) -> PalettePreference {
    defaults.string(forKey: AgentHubDefaults.palette)
      .flatMap(PalettePreference.init(rawValue:)) ?? .defaultPalette
  }

  static func apply(_ preference: AppearancePreference, to target: AppearanceApplying?) {
    target?.appearance = appearance(for: preference)
  }

  /// At launch of the new shell: apply the stored appearance. The palette is
  /// already resolved by `WorkbenchThemeRegistry` when it is created.
  static func applyStoredAppearance(
    defaults: UserDefaults = .standard,
    to target: AppearanceApplying? = NSApp
  ) {
    apply(storedAppearance(defaults: defaults), to: target)
  }

  /// Settings › Appearance: persist and apply at once.
  static func selectAppearance(
    _ preference: AppearancePreference,
    defaults: UserDefaults = .standard,
    to target: AppearanceApplying? = NSApp
  ) {
    defaults.set(preference.rawValue, forKey: AgentHubDefaults.appearance)
    apply(preference, to: target)
  }

  /// Settings › Palette: the registry persists, invalidates colours and bumps
  /// its revision so open windows redraw.
  static func selectPalette(_ preference: PalettePreference) {
    WorkbenchThemeRegistry.shared.setPalette(preference)
  }

  /// The palette's "Switch appearance": the explicit opposite of what shows now.
  static func toggledAppearance(currentlyDark: Bool) -> AppearancePreference {
    currentlyDark ? .light : .dark
  }

  static var isShowingDark: Bool {
    NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }
}

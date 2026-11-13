//
//  Color+WorkbenchTokens.swift
//  AgentHub
//
//  Dynamic `Color` and `NSColor` tokens that resolve light/dark from
//  the active `WorkbenchThemeRegistry.current` palette.
//
//  Each token is backed by a cached `NSColor(name:dynamicProvider:)` so
//  SwiftUI picks up appearance changes automatically. The `Color` twin
//  wraps it with `Color(nsColor:)`.
//

import AppKit
import SwiftUI

// MARK: - Dynamic token cache

/// Caches `NSColor` instances keyed by token name so each is created once.
/// Thread-safe: all access happens on @MainActor through the public API.
/// Internal so `WorkbenchThemeRegistry` can invalidate it on palette switch.
@MainActor
final class WorkbenchColorCache {
  static let shared = WorkbenchColorCache()

  private var cache: [String: NSColor] = [:]

  func color(named name: String, light: @escaping () -> SRGBA, dark: @escaping () -> SRGBA) -> NSColor {
    if let cached = cache[name] { return cached }
    let ns = NSColor(name: NSColor.Name(name)) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let srgba = isDark ? dark() : light()
      return srgba.nsColor
    }
    cache[name] = ns
    return ns
  }

  /// Invalidate the cache when the theme changes.
  func invalidate() {
    cache.removeAll()
  }
}

// MARK: - Token accessor helper

/// Builds a dynamic NSColor that reads from the current registry palette.
@MainActor
private func wbDynamic(_ name: String, _ path: KeyPath<WorkbenchPalette, SRGBA>) -> NSColor {
  WorkbenchColorCache.shared.color(
    named: "wb.\(name)",
    light: { WorkbenchThemeRegistry.shared.current.light[keyPath: path] },
    dark: { WorkbenchThemeRegistry.shared.current.dark[keyPath: path] }
  )
}

// MARK: - NSColor workbench tokens

extension NSColor {
  // Surfaces
  @MainActor public static var wbSurfaceDesktop: NSColor { wbDynamic("surfaceDesktop", \.surfaceDesktop) }
  @MainActor public static var wbSurfaceWindow: NSColor { wbDynamic("surfaceWindow", \.surfaceWindow) }
  @MainActor public static var wbSurfaceSidebar: NSColor { wbDynamic("surfaceSidebar", \.surfaceSidebar) }
  @MainActor public static var wbSurfaceContent: NSColor { wbDynamic("surfaceContent", \.surfaceContent) }
  @MainActor public static var wbSurfaceRaised: NSColor { wbDynamic("surfaceRaised", \.surfaceRaised) }
  @MainActor public static var wbSurfaceOverlay: NSColor { wbDynamic("surfaceOverlay", \.surfaceOverlay) }
  @MainActor public static var wbSurfaceColumn: NSColor { wbDynamic("surfaceColumn", \.surfaceColumn) }
  @MainActor public static var wbSurfaceTerminal: NSColor { wbDynamic("surfaceTerminal", \.surfaceTerminal) }
  @MainActor public static var wbSurfaceField: NSColor { wbDynamic("surfaceField", \.surfaceField) }
  @MainActor public static var wbSurfaceKeycap: NSColor { wbDynamic("surfaceKeycap", \.surfaceKeycap) }
  @MainActor public static var wbSurfaceHover: NSColor { wbDynamic("surfaceHover", \.surfaceHover) }
  @MainActor public static var wbSurfacePressed: NSColor { wbDynamic("surfacePressed", \.surfacePressed) }
  @MainActor public static var wbSurfaceSelected: NSColor { wbDynamic("surfaceSelected", \.surfaceSelected) }
  @MainActor public static var wbSurfaceControl: NSColor { wbDynamic("surfaceControl", \.surfaceControl) }
  @MainActor public static var wbSurfaceControlHover: NSColor { wbDynamic("surfaceControlHover", \.surfaceControlHover) }
  @MainActor public static var wbSurfaceSegmentSelected: NSColor { wbDynamic("surfaceSegmentSelected", \.surfaceSegmentSelected) }
  @MainActor public static var wbSurfaceScrim: NSColor { wbDynamic("surfaceScrim", \.surfaceScrim) }
  @MainActor public static var wbSurfaceTooltip: NSColor { wbDynamic("surfaceTooltip", \.surfaceTooltip) }

  // Text
  @MainActor public static var wbTextPrimary: NSColor { wbDynamic("textPrimary", \.textPrimary) }
  @MainActor public static var wbTextSecondary: NSColor { wbDynamic("textSecondary", \.textSecondary) }
  @MainActor public static var wbTextTertiary: NSColor { wbDynamic("textTertiary", \.textTertiary) }
  @MainActor public static var wbTextOnAccent: NSColor { wbDynamic("textOnAccent", \.textOnAccent) }
  @MainActor public static var wbTextPlaceholder: NSColor { wbDynamic("textPlaceholder", \.textPlaceholder) }
  @MainActor public static var wbTextTooltip: NSColor { wbDynamic("textTooltip", \.textTooltip) }

  // Borders
  @MainActor public static var wbBorderHairline: NSColor { wbDynamic("borderHairline", \.borderHairline) }
  @MainActor public static var wbBorderControl: NSColor { wbDynamic("borderControl", \.borderControl) }
  @MainActor public static var wbBorderStrong: NSColor { wbDynamic("borderStrong", \.borderStrong) }

  // Accent
  @MainActor public static var wbAccent: NSColor { wbDynamic("accent", \.accent) }
  @MainActor public static var wbAccentHover: NSColor { wbDynamic("accentHover", \.accentHover) }
  @MainActor public static var wbAccentText: NSColor { wbDynamic("accentText", \.accentText) }
  @MainActor public static var wbAccentTint: NSColor { wbDynamic("accentTint", \.accentTint) }
  @MainActor public static var wbFocusRing: NSColor { wbDynamic("focusRing", \.focusRing) }

  // Status
  @MainActor public static var wbStatusWorkingFill: NSColor { wbDynamic("statusWorkingFill", \.statusWorkingFill) }
  @MainActor public static var wbStatusWorkingText: NSColor { wbDynamic("statusWorkingText", \.statusWorkingText) }
  @MainActor public static var wbStatusWorkingTint: NSColor { wbDynamic("statusWorkingTint", \.statusWorkingTint) }
  @MainActor public static var wbStatusReadyFill: NSColor { wbDynamic("statusReadyFill", \.statusReadyFill) }
  @MainActor public static var wbStatusReadyText: NSColor { wbDynamic("statusReadyText", \.statusReadyText) }
  @MainActor public static var wbStatusReadyTint: NSColor { wbDynamic("statusReadyTint", \.statusReadyTint) }
  @MainActor public static var wbStatusAttentionFill: NSColor { wbDynamic("statusAttentionFill", \.statusAttentionFill) }
  @MainActor public static var wbStatusAttentionText: NSColor { wbDynamic("statusAttentionText", \.statusAttentionText) }
  @MainActor public static var wbStatusAttentionTint: NSColor { wbDynamic("statusAttentionTint", \.statusAttentionTint) }
  @MainActor public static var wbStatusIdleFill: NSColor { wbDynamic("statusIdleFill", \.statusIdleFill) }
  @MainActor public static var wbStatusIdleText: NSColor { wbDynamic("statusIdleText", \.statusIdleText) }
  @MainActor public static var wbStatusIdleTint: NSColor { wbDynamic("statusIdleTint", \.statusIdleTint) }
  @MainActor public static var wbStatusErrorFill: NSColor { wbDynamic("statusErrorFill", \.statusErrorFill) }
  @MainActor public static var wbStatusErrorText: NSColor { wbDynamic("statusErrorText", \.statusErrorText) }
  @MainActor public static var wbStatusErrorTint: NSColor { wbDynamic("statusErrorTint", \.statusErrorTint) }
  @MainActor public static var wbStatusGlyphInk: NSColor { wbDynamic("statusGlyphInk", \.statusGlyphInk) }

  // Diff
  @MainActor public static var wbDiffAddedTint: NSColor { wbDynamic("diffAddedTint", \.diffAddedTint) }
  @MainActor public static var wbDiffAddedText: NSColor { wbDynamic("diffAddedText", \.diffAddedText) }
  @MainActor public static var wbDiffRemovedTint: NSColor { wbDynamic("diffRemovedTint", \.diffRemovedTint) }
  @MainActor public static var wbDiffRemovedText: NSColor { wbDynamic("diffRemovedText", \.diffRemovedText) }

  // ANSI
  @MainActor public static var wbAnsiGreen: NSColor { wbDynamic("ansiGreen", \.ansiGreen) }
  @MainActor public static var wbAnsiRed: NSColor { wbDynamic("ansiRed", \.ansiRed) }
  @MainActor public static var wbAnsiOrange: NSColor { wbDynamic("ansiOrange", \.ansiOrange) }
  @MainActor public static var wbAnsiBlue: NSColor { wbDynamic("ansiBlue", \.ansiBlue) }

  // Tile
  @MainActor public static var wbTileViolet: NSColor { wbDynamic("tileViolet", \.tileViolet) }
  @MainActor public static var wbTileTeal: NSColor { wbDynamic("tileTeal", \.tileTeal) }
  @MainActor public static var wbTileOrange: NSColor { wbDynamic("tileOrange", \.tileOrange) }

  // Meter
  @MainActor public static var wbMeterEmpty: NSColor { wbDynamic("meterEmpty", \.meterEmpty) }
  @MainActor public static var wbMeterFull: NSColor { wbDynamic("meterFull", \.meterFull) }

  // Link
  @MainActor public static var wbLinkUnderline: NSColor { wbDynamic("linkUnderline", \.linkUnderline) }
}

// MARK: - Color workbench tokens (SwiftUI wrappers)

extension Color {
  // Surfaces
  @MainActor public static var wbSurfaceDesktop: Color { Color(nsColor: .wbSurfaceDesktop) }
  @MainActor public static var wbSurfaceWindow: Color { Color(nsColor: .wbSurfaceWindow) }
  @MainActor public static var wbSurfaceSidebar: Color { Color(nsColor: .wbSurfaceSidebar) }
  @MainActor public static var wbSurfaceContent: Color { Color(nsColor: .wbSurfaceContent) }
  @MainActor public static var wbSurfaceRaised: Color { Color(nsColor: .wbSurfaceRaised) }
  @MainActor public static var wbSurfaceOverlay: Color { Color(nsColor: .wbSurfaceOverlay) }
  @MainActor public static var wbSurfaceColumn: Color { Color(nsColor: .wbSurfaceColumn) }
  @MainActor public static var wbSurfaceTerminal: Color { Color(nsColor: .wbSurfaceTerminal) }
  @MainActor public static var wbSurfaceField: Color { Color(nsColor: .wbSurfaceField) }
  @MainActor public static var wbSurfaceKeycap: Color { Color(nsColor: .wbSurfaceKeycap) }
  @MainActor public static var wbSurfaceHover: Color { Color(nsColor: .wbSurfaceHover) }
  @MainActor public static var wbSurfacePressed: Color { Color(nsColor: .wbSurfacePressed) }
  @MainActor public static var wbSurfaceSelected: Color { Color(nsColor: .wbSurfaceSelected) }
  @MainActor public static var wbSurfaceControl: Color { Color(nsColor: .wbSurfaceControl) }
  @MainActor public static var wbSurfaceControlHover: Color { Color(nsColor: .wbSurfaceControlHover) }
  @MainActor public static var wbSurfaceSegmentSelected: Color { Color(nsColor: .wbSurfaceSegmentSelected) }
  @MainActor public static var wbSurfaceScrim: Color { Color(nsColor: .wbSurfaceScrim) }
  @MainActor public static var wbSurfaceTooltip: Color { Color(nsColor: .wbSurfaceTooltip) }

  // Text
  @MainActor public static var wbTextPrimary: Color { Color(nsColor: .wbTextPrimary) }
  @MainActor public static var wbTextSecondary: Color { Color(nsColor: .wbTextSecondary) }
  @MainActor public static var wbTextTertiary: Color { Color(nsColor: .wbTextTertiary) }
  @MainActor public static var wbTextOnAccent: Color { Color(nsColor: .wbTextOnAccent) }
  @MainActor public static var wbTextPlaceholder: Color { Color(nsColor: .wbTextPlaceholder) }
  @MainActor public static var wbTextTooltip: Color { Color(nsColor: .wbTextTooltip) }

  // Borders
  @MainActor public static var wbBorderHairline: Color { Color(nsColor: .wbBorderHairline) }
  @MainActor public static var wbBorderControl: Color { Color(nsColor: .wbBorderControl) }
  @MainActor public static var wbBorderStrong: Color { Color(nsColor: .wbBorderStrong) }

  // Accent
  @MainActor public static var wbAccent: Color { Color(nsColor: .wbAccent) }
  @MainActor public static var wbAccentHover: Color { Color(nsColor: .wbAccentHover) }
  @MainActor public static var wbAccentText: Color { Color(nsColor: .wbAccentText) }
  @MainActor public static var wbAccentTint: Color { Color(nsColor: .wbAccentTint) }
  @MainActor public static var wbFocusRing: Color { Color(nsColor: .wbFocusRing) }

  // Status
  @MainActor public static var wbStatusWorkingFill: Color { Color(nsColor: .wbStatusWorkingFill) }
  @MainActor public static var wbStatusWorkingText: Color { Color(nsColor: .wbStatusWorkingText) }
  @MainActor public static var wbStatusWorkingTint: Color { Color(nsColor: .wbStatusWorkingTint) }
  @MainActor public static var wbStatusReadyFill: Color { Color(nsColor: .wbStatusReadyFill) }
  @MainActor public static var wbStatusReadyText: Color { Color(nsColor: .wbStatusReadyText) }
  @MainActor public static var wbStatusReadyTint: Color { Color(nsColor: .wbStatusReadyTint) }
  @MainActor public static var wbStatusAttentionFill: Color { Color(nsColor: .wbStatusAttentionFill) }
  @MainActor public static var wbStatusAttentionText: Color { Color(nsColor: .wbStatusAttentionText) }
  @MainActor public static var wbStatusAttentionTint: Color { Color(nsColor: .wbStatusAttentionTint) }
  @MainActor public static var wbStatusIdleFill: Color { Color(nsColor: .wbStatusIdleFill) }
  @MainActor public static var wbStatusIdleText: Color { Color(nsColor: .wbStatusIdleText) }
  @MainActor public static var wbStatusIdleTint: Color { Color(nsColor: .wbStatusIdleTint) }
  @MainActor public static var wbStatusErrorFill: Color { Color(nsColor: .wbStatusErrorFill) }
  @MainActor public static var wbStatusErrorText: Color { Color(nsColor: .wbStatusErrorText) }
  @MainActor public static var wbStatusErrorTint: Color { Color(nsColor: .wbStatusErrorTint) }
  @MainActor public static var wbStatusGlyphInk: Color { Color(nsColor: .wbStatusGlyphInk) }

  // Diff
  @MainActor public static var wbDiffAddedTint: Color { Color(nsColor: .wbDiffAddedTint) }
  @MainActor public static var wbDiffAddedText: Color { Color(nsColor: .wbDiffAddedText) }
  @MainActor public static var wbDiffRemovedTint: Color { Color(nsColor: .wbDiffRemovedTint) }
  @MainActor public static var wbDiffRemovedText: Color { Color(nsColor: .wbDiffRemovedText) }

  // ANSI
  @MainActor public static var wbAnsiGreen: Color { Color(nsColor: .wbAnsiGreen) }
  @MainActor public static var wbAnsiRed: Color { Color(nsColor: .wbAnsiRed) }
  @MainActor public static var wbAnsiOrange: Color { Color(nsColor: .wbAnsiOrange) }
  @MainActor public static var wbAnsiBlue: Color { Color(nsColor: .wbAnsiBlue) }

  // Tile
  @MainActor public static var wbTileViolet: Color { Color(nsColor: .wbTileViolet) }
  @MainActor public static var wbTileTeal: Color { Color(nsColor: .wbTileTeal) }
  @MainActor public static var wbTileOrange: Color { Color(nsColor: .wbTileOrange) }

  // Meter
  @MainActor public static var wbMeterEmpty: Color { Color(nsColor: .wbMeterEmpty) }
  @MainActor public static var wbMeterFull: Color { Color(nsColor: .wbMeterFull) }

  // Link
  @MainActor public static var wbLinkUnderline: Color { Color(nsColor: .wbLinkUnderline) }
}

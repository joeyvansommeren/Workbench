//
//  WorkbenchPalette.swift
//  AgentHub
//
//  Token-accurate colour palette. Every value matches the CSS tokens
//  in workbench-apple.html one-to-one. The fixture at
//  Tests/AgentHubTests/Fixtures/workbench-apple-tokens.css guards parity.
//

import AppKit

// MARK: - RGBA storage

/// A colour value stored as sRGB components with premultiplied alpha.
/// Used as the palette's storage type so values are trivially comparable
/// and convertible to both `NSColor` and `Color`.
public struct SRGBA: Equatable, Sendable {
  public let r: CGFloat
  public let g: CGFloat
  public let b: CGFloat
  public let a: CGFloat

  /// Create from 0-255 integer components.
  public init(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) {
    self.r = CGFloat(r) / 255
    self.g = CGFloat(g) / 255
    self.b = CGFloat(b) / 255
    self.a = a
  }

  /// Create from 0-1 float components.
  public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }

  /// Create from a 6-digit hex string like `#1D1D1F` or `1D1D1F`.
  public init(hex: String, alpha: CGFloat = 1) {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int = UInt64()
    Scanner(string: cleaned).scanHexInt64(&int)
    self.init(Int((int >> 16) & 0xFF), Int((int >> 8) & 0xFF), Int(int & 0xFF), alpha)
  }

  public var nsColor: NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
  }

  /// Relative luminance per WCAG 2.1.
  public var relativeLuminance: CGFloat {
    func linearise(_ c: CGFloat) -> CGFloat {
      c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearise(r) + 0.7152 * linearise(g) + 0.0722 * linearise(b)
  }

  /// WCAG contrast ratio between two colours.
  public func contrastRatio(with other: SRGBA) -> CGFloat {
    let l1 = max(relativeLuminance, other.relativeLuminance)
    let l2 = min(relativeLuminance, other.relativeLuminance)
    return (l1 + 0.05) / (l2 + 0.05)
  }
}

// MARK: - Palette

/// Every semantic colour token for one appearance (light or dark).
/// Values are literal sRGB+alpha, copied from the CSS `:root` / `[data-theme]`
/// blocks in the prototype HTML.
public struct WorkbenchPalette: Equatable, Sendable {

  // -- Surfaces --
  public let surfaceDesktop: SRGBA
  public let surfaceWindow: SRGBA
  public let surfaceSidebar: SRGBA
  public let surfaceContent: SRGBA
  public let surfaceRaised: SRGBA
  public let surfaceOverlay: SRGBA
  public let surfaceColumn: SRGBA
  public let surfaceTerminal: SRGBA
  public let surfaceField: SRGBA
  public let surfaceKeycap: SRGBA
  public let surfaceHover: SRGBA
  public let surfacePressed: SRGBA
  public let surfaceSelected: SRGBA
  public let surfaceControl: SRGBA
  public let surfaceControlHover: SRGBA
  public let surfaceSegmentSelected: SRGBA
  public let surfaceScrim: SRGBA
  public let surfaceTooltip: SRGBA

  // -- Text --
  public let textPrimary: SRGBA
  public let textSecondary: SRGBA
  public let textTertiary: SRGBA
  public let textOnAccent: SRGBA
  public let textPlaceholder: SRGBA
  public let textTooltip: SRGBA

  // -- Borders --
  public let borderHairline: SRGBA
  public let borderControl: SRGBA
  public let borderStrong: SRGBA

  // -- Accent --
  public let accent: SRGBA
  public let accentHover: SRGBA
  public let accentText: SRGBA
  public let accentTint: SRGBA
  public let focusRing: SRGBA

  // -- Status --
  public let statusWorkingFill: SRGBA
  public let statusWorkingText: SRGBA
  public let statusWorkingTint: SRGBA
  public let statusReadyFill: SRGBA
  public let statusReadyText: SRGBA
  public let statusReadyTint: SRGBA
  public let statusAttentionFill: SRGBA
  public let statusAttentionText: SRGBA
  public let statusAttentionTint: SRGBA
  public let statusIdleFill: SRGBA
  public let statusIdleText: SRGBA
  public let statusIdleTint: SRGBA
  public let statusErrorFill: SRGBA
  public let statusErrorText: SRGBA
  public let statusErrorTint: SRGBA
  public let statusGlyphInk: SRGBA

  // -- Diff --
  public let diffAddedTint: SRGBA
  public let diffAddedText: SRGBA
  public let diffRemovedTint: SRGBA
  public let diffRemovedText: SRGBA

  // -- ANSI --
  public let ansiGreen: SRGBA
  public let ansiRed: SRGBA
  public let ansiOrange: SRGBA
  public let ansiBlue: SRGBA

  // -- Tile --
  public let tileViolet: SRGBA
  public let tileTeal: SRGBA
  public let tileOrange: SRGBA

  // -- Meter --
  public let meterEmpty: SRGBA
  public let meterFull: SRGBA

  // -- Link --
  /// Underline colour for text links. Standard uses transparent (links
  /// are accent-coloured). Warm uses an ink-coloured underline because
  /// its accent is ink.
  public let linkUnderline: SRGBA
}

// MARK: - Apple palette literals

extension WorkbenchPalette {

  /// Light appearance — matches `[data-theme="light"]` in the prototype.
  public static let appleLight = WorkbenchPalette(
    surfaceDesktop: .init(hex: "#DADBDF"),
    surfaceWindow: .init(hex: "#F3F3F4"),
    surfaceSidebar: .init(hex: "#F3F3F4"),
    surfaceContent: .init(hex: "#FFFFFF"),
    surfaceRaised: .init(hex: "#FFFFFF"),
    surfaceOverlay: .init(255, 255, 255, 0.96),
    surfaceColumn: .init(hex: "#F6F6F7"),
    surfaceTerminal: .init(hex: "#FFFFFF"),
    surfaceField: .init(0, 0, 0, 0.045),
    surfaceKeycap: .init(0, 0, 0, 0.06),
    surfaceHover: .init(0, 0, 0, 0.045),
    surfacePressed: .init(0, 0, 0, 0.08),
    surfaceSelected: .init(0, 0, 0, 0.065),
    surfaceControl: .init(hex: "#FFFFFF"),
    surfaceControlHover: .init(hex: "#F0F0F1"),
    surfaceSegmentSelected: .init(hex: "#FFFFFF"),
    surfaceScrim: .init(24, 24, 28, 0.18),
    surfaceTooltip: .init(hex: "#F7F7F8"),
    textPrimary: .init(hex: "#1D1D1F"),
    textSecondary: .init(hex: "#5C5C62"),
    textTertiary: .init(hex: "#636369"),
    textOnAccent: .init(hex: "#FFFFFF"),
    textPlaceholder: .init(hex: "#636369"),
    textTooltip: .init(hex: "#1D1D1F"),
    borderHairline: .init(0, 0, 0, 0.08),
    borderControl: .init(0, 0, 0, 0.14),
    borderStrong: .init(0, 0, 0, 0.22),
    accent: .init(hex: "#0A6CDC"),
    accentHover: .init(hex: "#095FC4"),
    accentText: .init(hex: "#0066D6"),
    accentTint: .init(10, 108, 220, 0.10),
    focusRing: .init(10, 108, 220, 0.55),
    statusWorkingFill: .init(hex: "#0A6CDC"),
    statusWorkingText: .init(hex: "#0060C9"),
    statusWorkingTint: .init(hex: "#E6F0FC"),
    statusReadyFill: .init(hex: "#23A047"),
    statusReadyText: .init(hex: "#1E7A34"),
    statusReadyTint: .init(hex: "#E8F5EC"),
    statusAttentionFill: .init(hex: "#F08A00"),
    statusAttentionText: .init(hex: "#A34A00"),
    statusAttentionTint: .init(hex: "#FFF1E0"),
    statusIdleFill: .init(hex: "#8E8E93"),
    statusIdleText: .init(hex: "#5C5C62"),
    statusIdleTint: .init(0, 0, 0, 0.05),
    statusErrorFill: .init(hex: "#E5484D"),
    statusErrorText: .init(hex: "#C42B2B"),
    statusErrorTint: .init(hex: "#FDECEC"),
    statusGlyphInk: .init(hex: "#FFFFFF"),
    diffAddedTint: .init(hex: "#E9F6EC"),
    diffAddedText: .init(hex: "#1E7A34"),
    diffRemovedTint: .init(hex: "#FCECEC"),
    diffRemovedText: .init(hex: "#B42323"),
    ansiGreen: .init(hex: "#1E7A34"),
    ansiRed: .init(hex: "#B42323"),
    ansiOrange: .init(hex: "#A34A00"),
    ansiBlue: .init(hex: "#0060C9"),
    tileViolet: .init(hex: "#6E56CF"),
    tileTeal: .init(hex: "#0F7C86"),
    tileOrange: .init(hex: "#C2410C"),
    meterEmpty: .init(0, 0, 0, 0.12),
    meterFull: .init(hex: "#3A3A3F"),
    linkUnderline: .init(r: 0, g: 0, b: 0, a: 0) // transparent
  )

  /// Dark appearance — matches `[data-theme="dark"]` in the prototype.
  public static let appleDark = WorkbenchPalette(
    surfaceDesktop: .init(hex: "#050506"),
    surfaceWindow: .init(hex: "#131315"),
    surfaceSidebar: .init(hex: "#131315"),
    surfaceContent: .init(hex: "#1C1C1F"),
    surfaceRaised: .init(hex: "#2A2A2E"),
    surfaceOverlay: .init(50, 50, 55, 0.96),
    surfaceColumn: .init(hex: "#212124"),
    surfaceTerminal: .init(hex: "#1C1C1F"),
    surfaceField: .init(255, 255, 255, 0.06),
    surfaceKeycap: .init(255, 255, 255, 0.09),
    surfaceHover: .init(255, 255, 255, 0.055),
    surfacePressed: .init(255, 255, 255, 0.09),
    surfaceSelected: .init(255, 255, 255, 0.08),
    surfaceControl: .init(255, 255, 255, 0.10),
    surfaceControlHover: .init(255, 255, 255, 0.15),
    surfaceSegmentSelected: .init(255, 255, 255, 0.16),
    surfaceScrim: .init(0, 0, 0, 0.45),
    surfaceTooltip: .init(hex: "#3A3A3E"),
    textPrimary: .init(hex: "#F2F2F5"),
    textSecondary: .init(hex: "#B3B3BA"),
    textTertiary: .init(hex: "#A0A0A7"),
    textOnAccent: .init(hex: "#FFFFFF"),
    textPlaceholder: .init(hex: "#A0A0A7"),
    textTooltip: .init(hex: "#F2F2F5"),
    borderHairline: .init(255, 255, 255, 0.08),
    borderControl: .init(255, 255, 255, 0.14),
    borderStrong: .init(255, 255, 255, 0.24),
    accent: .init(hex: "#1F6FEB"),
    accentHover: .init(hex: "#1A63D6"),
    accentText: .init(hex: "#4DA3FF"),
    accentTint: .init(77, 163, 255, 0.14),
    focusRing: .init(77, 163, 255, 0.6),
    statusWorkingFill: .init(hex: "#4DA3FF"),
    statusWorkingText: .init(hex: "#6CB4FF"),
    statusWorkingTint: .init(77, 163, 255, 0.14),
    statusReadyFill: .init(hex: "#4CC76B"),
    statusReadyText: .init(hex: "#5FD47D"),
    statusReadyTint: .init(76, 199, 107, 0.14),
    statusAttentionFill: .init(hex: "#FFA53A"),
    statusAttentionText: .init(hex: "#FFB45E"),
    statusAttentionTint: .init(255, 165, 58, 0.15),
    statusIdleFill: .init(hex: "#8E8E95"),
    statusIdleText: .init(hex: "#B3B3BA"),
    statusIdleTint: .init(255, 255, 255, 0.07),
    statusErrorFill: .init(hex: "#FF6B6B"),
    statusErrorText: .init(hex: "#FF8080"),
    statusErrorTint: .init(255, 107, 107, 0.14),
    statusGlyphInk: .init(hex: "#141416"),
    diffAddedTint: .init(76, 199, 107, 0.12),
    diffAddedText: .init(hex: "#6FD68A"),
    diffRemovedTint: .init(255, 107, 107, 0.12),
    diffRemovedText: .init(hex: "#FF8C8C"),
    ansiGreen: .init(hex: "#6FD68A"),
    ansiRed: .init(hex: "#FF8C8C"),
    ansiOrange: .init(hex: "#FFB45E"),
    ansiBlue: .init(hex: "#6CB4FF"),
    tileViolet: .init(hex: "#6E56CF"),
    tileTeal: .init(hex: "#0F7C86"),
    tileOrange: .init(hex: "#C2410C"),
    meterEmpty: .init(255, 255, 255, 0.14),
    meterFull: .init(hex: "#E4E4E8"),
    linkUnderline: .init(r: 0, g: 0, b: 0, a: 0) // transparent
  )

  // MARK: - Apple Warm palette literals

  /// Light warm appearance.
  public static let appleWarmLight = WorkbenchPalette(
    surfaceDesktop: .init(hex: "#DDD8D0"),
    surfaceWindow: .init(hex: "#F3F1EC"),
    surfaceSidebar: .init(hex: "#F3F1EC"),
    surfaceContent: .init(hex: "#FCFBF9"),
    surfaceRaised: .init(hex: "#FFFEFC"),
    surfaceOverlay: .init(255, 254, 251, 0.96),
    surfaceColumn: .init(hex: "#F6F4F0"),
    surfaceTerminal: .init(hex: "#FCFBF9"),
    surfaceField: .init(70, 50, 30, 0.055),
    surfaceKeycap: .init(70, 50, 30, 0.075),
    surfaceHover: .init(70, 50, 30, 0.05),
    surfacePressed: .init(70, 50, 30, 0.09),
    surfaceSelected: .init(70, 50, 30, 0.07),
    surfaceControl: .init(hex: "#FFFEFC"),
    surfaceControlHover: .init(hex: "#F4F1EC"),
    surfaceSegmentSelected: .init(hex: "#FFFEFC"),
    surfaceScrim: .init(28, 25, 23, 0.2),
    surfaceTooltip: .init(hex: "#FAF8F4"),
    textPrimary: .init(hex: "#1C1917"),
    textSecondary: .init(hex: "#5F5851"),
    textTertiary: .init(hex: "#67605A"),
    textOnAccent: .init(hex: "#FFFFFF"),
    textPlaceholder: .init(hex: "#67605A"),
    textTooltip: .init(hex: "#1C1917"),
    borderHairline: .init(70, 50, 30, 0.1),
    borderControl: .init(70, 50, 30, 0.16),
    borderStrong: .init(70, 50, 30, 0.26),
    accent: .init(hex: "#1C1917"),
    accentHover: .init(hex: "#3D3631"),
    accentText: .init(hex: "#1C1917"),
    accentTint: .init(196, 128, 58, 0.18),
    focusRing: .init(196, 128, 58, 0.6),
    statusWorkingFill: .init(hex: "#3A6EA5"),
    statusWorkingText: .init(hex: "#2B5B8C"),
    statusWorkingTint: .init(hex: "#E6EDF3"),
    statusReadyFill: .init(hex: "#3F8F4E"),
    statusReadyText: .init(hex: "#2E6B3A"),
    statusReadyTint: .init(hex: "#E6F0E2"),
    statusAttentionFill: .init(hex: "#D98B1E"),
    statusAttentionText: .init(hex: "#8A5300"),
    statusAttentionTint: .init(hex: "#F8EBD3"),
    statusIdleFill: .init(hex: "#9A928A"),
    statusIdleText: .init(hex: "#5F5851"),
    statusIdleTint: .init(70, 50, 30, 0.06),
    statusErrorFill: .init(hex: "#C8452F"),
    statusErrorText: .init(hex: "#A3311F"),
    statusErrorTint: .init(hex: "#F8E4DE"),
    statusGlyphInk: .init(hex: "#FFFFFF"),
    diffAddedTint: .init(hex: "#E7F0E1"),
    diffAddedText: .init(hex: "#2E6B3A"),
    diffRemovedTint: .init(hex: "#F8E6E0"),
    diffRemovedText: .init(hex: "#A3311F"),
    ansiGreen: .init(hex: "#2E6B3A"),
    ansiRed: .init(hex: "#A3311F"),
    ansiOrange: .init(hex: "#8A5300"),
    ansiBlue: .init(hex: "#2B5B8C"),
    tileViolet: .init(hex: "#6B5BB5"),
    tileTeal: .init(hex: "#2F7A72"),
    tileOrange: .init(hex: "#B4532A"),
    meterEmpty: .init(70, 50, 30, 0.14),
    meterFull: .init(hex: "#3A342F"),
    linkUnderline: .init(28, 25, 23, 0.35)
  )

  /// Dark warm appearance.
  public static let appleWarmDark = WorkbenchPalette(
    surfaceDesktop: .init(hex: "#0C0A09"),
    surfaceWindow: .init(hex: "#171412"),
    surfaceSidebar: .init(hex: "#171412"),
    surfaceContent: .init(hex: "#1F1C19"),
    surfaceRaised: .init(hex: "#2C2824"),
    surfaceOverlay: .init(52, 48, 42, 0.96),
    surfaceColumn: .init(hex: "#24201D"),
    surfaceTerminal: .init(hex: "#1F1C19"),
    surfaceField: .init(255, 240, 220, 0.06),
    surfaceKeycap: .init(255, 240, 220, 0.09),
    surfaceHover: .init(255, 240, 220, 0.055),
    surfacePressed: .init(255, 240, 220, 0.09),
    surfaceSelected: .init(255, 240, 220, 0.08),
    surfaceControl: .init(255, 240, 220, 0.1),
    surfaceControlHover: .init(255, 240, 220, 0.15),
    surfaceSegmentSelected: .init(255, 240, 220, 0.16),
    surfaceScrim: .init(0, 0, 0, 0.5),
    surfaceTooltip: .init(hex: "#3A3530"),
    textPrimary: .init(hex: "#F3EEE8"),
    textSecondary: .init(hex: "#BDB4AA"),
    textTertiary: .init(hex: "#ABA298"),
    textOnAccent: .init(hex: "#1C1917"),
    textPlaceholder: .init(hex: "#ABA298"),
    textTooltip: .init(hex: "#F5F0EA"),
    borderHairline: .init(255, 240, 220, 0.09),
    borderControl: .init(255, 240, 220, 0.15),
    borderStrong: .init(255, 240, 220, 0.25),
    accent: .init(hex: "#F3EEE8"),
    accentHover: .init(hex: "#DDD6CE"),
    accentText: .init(hex: "#F3EEE8"),
    accentTint: .init(230, 165, 95, 0.2),
    focusRing: .init(230, 165, 95, 0.6),
    statusWorkingFill: .init(hex: "#7FA7D9"),
    statusWorkingText: .init(hex: "#93B6E0"),
    statusWorkingTint: .init(127, 167, 217, 0.15),
    statusReadyFill: .init(hex: "#7DBE84"),
    statusReadyText: .init(hex: "#8FCB95"),
    statusReadyTint: .init(125, 190, 132, 0.14),
    statusAttentionFill: .init(hex: "#E7A84A"),
    statusAttentionText: .init(hex: "#EDB866"),
    statusAttentionTint: .init(231, 168, 74, 0.15),
    statusIdleFill: .init(hex: "#8F877E"),
    statusIdleText: .init(hex: "#BDB4AA"),
    statusIdleTint: .init(255, 240, 220, 0.07),
    statusErrorFill: .init(hex: "#E97A63"),
    statusErrorText: .init(hex: "#F08C77"),
    statusErrorTint: .init(233, 122, 99, 0.15),
    statusGlyphInk: .init(hex: "#171412"),
    diffAddedTint: .init(125, 190, 132, 0.12),
    diffAddedText: .init(hex: "#93CF98"),
    diffRemovedTint: .init(233, 122, 99, 0.12),
    diffRemovedText: .init(hex: "#F29A86"),
    ansiGreen: .init(hex: "#93CF98"),
    ansiRed: .init(hex: "#F29A86"),
    ansiOrange: .init(hex: "#EDB866"),
    ansiBlue: .init(hex: "#93B6E0"),
    tileViolet: .init(hex: "#6B5BB5"),
    tileTeal: .init(hex: "#2F7A72"),
    tileOrange: .init(hex: "#B4532A"),
    meterEmpty: .init(255, 240, 220, 0.14),
    meterFull: .init(hex: "#E9E2DA"),
    linkUnderline: .init(243, 238, 232, 0.4)
  )
}

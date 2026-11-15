//
//  TerminalPalette.swift
//  AgentHub
//
//  The terminal colours of the new shell, derived from a `WorkbenchPalette`
//  so the terminal follows the theme (light terminal in light mode).
//
//  Four ANSI hues come straight from the tokens (green, red, orange as
//  yellow, blue); magenta and cyan come from the tile tokens; the greys and
//  the bright row are derived. Every ANSI slot is then nudged toward the
//  foreground until it reaches 3:1 against the background.
//

import Foundation

public struct TerminalPalette: Equatable, Sendable {
  public let background: SRGBA
  public let foreground: SRGBA
  public let cursor: SRGBA
  /// Selection highlight, composited over the background (opaque).
  public let selection: SRGBA
  /// The 16 ANSI colours: 0–7 normal, 8–15 bright.
  public let ansi: [SRGBA]

  /// Minimum contrast of every ANSI slot against the background.
  public static let minimumANSIContrast: CGFloat = 3
  /// Minimum contrast of the foreground against the background.
  public static let minimumForegroundContrast: CGFloat = 4.5

  public init(palette: WorkbenchPalette, isDark: Bool) {
    let background = palette.surfaceTerminal
    self.background = background
    self.foreground = palette.textPrimary
    self.cursor = palette.textPrimary
    self.selection = palette.accentTint.composited(over: background)

    let white = SRGBA(r: 1, g: 1, b: 1)
    let black = SRGBA(r: 0, g: 0, b: 0)
    // Bright variants step away from the background: lighter on dark, darker on light.
    let brightTarget = isDark ? white : black
    let brightAmount: CGFloat = isDark ? 0.2 : 0.15
    let textTertiary = palette.textTertiary.composited(over: background)

    let normal: [SRGBA] = [
      isDark ? textTertiary : palette.textPrimary,  // 0 black
      palette.ansiRed,  // 1 red
      palette.ansiGreen,  // 2 green
      palette.ansiOrange,  // 3 yellow
      palette.ansiBlue,  // 4 blue
      palette.tileViolet,  // 5 magenta
      palette.tileTeal,  // 6 cyan
      palette.textSecondary.composited(over: background),  // 7 white
    ]
    let bright: [SRGBA] = [
      palette.textSecondary.composited(over: background),  // 8 bright black
      Self.mix(palette.ansiRed, brightTarget, brightAmount),
      Self.mix(palette.ansiGreen, brightTarget, brightAmount),
      Self.mix(palette.ansiOrange, brightTarget, brightAmount),
      Self.mix(palette.ansiBlue, brightTarget, brightAmount),
      Self.mix(palette.tileViolet, brightTarget, brightAmount),
      Self.mix(palette.tileTeal, brightTarget, brightAmount),
      palette.textPrimary,  // 15 bright white
    ]
    self.ansi = (normal + bright).map {
      Self.ensuringContrast(
        $0.composited(over: background),
        against: background,
        toward: palette.textPrimary,
        minimum: Self.minimumANSIContrast
      )
    }
  }

  /// Blends `color` toward `target` by `amount` (0...1).
  static func mix(_ color: SRGBA, _ target: SRGBA, _ amount: CGFloat) -> SRGBA {
    SRGBA(
      r: color.r + (target.r - color.r) * amount,
      g: color.g + (target.g - color.g) * amount,
      b: color.b + (target.b - color.b) * amount,
      a: color.a
    )
  }

  /// Moves `color` toward `target` in small steps until it reaches `minimum`
  /// contrast against `background`. Returns the colour unchanged when it
  /// already passes.
  static func ensuringContrast(
    _ color: SRGBA,
    against background: SRGBA,
    toward target: SRGBA,
    minimum: CGFloat
  ) -> SRGBA {
    var candidate = color
    var step = 0
    while candidate.contrastRatio(with: background) < minimum, step < 20 {
      step += 1
      candidate = mix(color, target, CGFloat(step) * 0.05)
    }
    return candidate
  }

  /// `#RRGGBB` for config files (Ghostty overlay).
  public static func hex(_ color: SRGBA) -> String {
    func channel(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", channel(color.r), channel(color.g), channel(color.b))
  }

  /// Stable text form of every colour, for change detection.
  public var signature: String {
    ([background, foreground, cursor, selection] + ansi).map(Self.hex).joined(separator: ",")
  }
}

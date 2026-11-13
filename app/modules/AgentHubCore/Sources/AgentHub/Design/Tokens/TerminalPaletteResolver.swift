//
//  TerminalPaletteResolver.swift
//  AgentHub
//
//  One place that decides the embedded terminal's colours.
//
//  - New shell (flag on): the terminal follows the Workbench palette, light in
//    light mode (`TerminalPalette`). YAML theme terminal colours are ignored.
//  - Legacy shell (flag off): the rules `EmbeddedTerminalView.updateColors`
//    always had: themed background/cursor in dark mode only, fixed light
//    colours, and ANSI colours left to the terminal's defaults.
//

import AppKit
import SwiftUI

/// The colours to apply to every terminal view of a workspace.
public struct ResolvedTerminalColors {
  public let background: NSColor
  public let foreground: NSColor
  public let cursor: NSColor
  /// Nil keeps the terminal's own selection colour (legacy).
  public let selection: NSColor?
  /// The 16 ANSI colours, or nil to keep the terminal's defaults (legacy).
  public let ansi: [SRGBA]?
  /// The palette these colours came from; nil in legacy mode. Part of the
  /// appearance fingerprint so a palette switch repaints open terminals.
  public let palette: TerminalPalette?
}

public enum TerminalPaletteResolver {
  /// Legacy dark background, foreground and cursor (unchanged values).
  static let legacyDarkBackground = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
  static let legacyDarkForeground = NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1.0)
  static let legacyLightForeground = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
  static let legacyCursor = NSColor(red: 204 / 255, green: 120 / 255, blue: 92 / 255, alpha: 1.0)
  @MainActor static var legacyLightBackground: NSColor { NSColor(Color.backgroundLight) }

  /// Pure resolution, for tests and for callers that already know the inputs.
  @MainActor
  public static func resolve(
    isDark: Bool,
    followsWorkbenchPalette: Bool,
    palette: WorkbenchPalette,
    theme: RuntimeTheme?
  ) -> ResolvedTerminalColors {
    if followsWorkbenchPalette {
      let terminal = TerminalPalette(palette: palette, isDark: isDark)
      return ResolvedTerminalColors(
        background: terminal.background.nsColor,
        foreground: terminal.foreground.nsColor,
        cursor: terminal.cursor.nsColor,
        selection: terminal.selection.nsColor,
        ansi: terminal.ansi,
        palette: terminal
      )
    }
    return legacy(isDark: isDark, themeBackground: theme?.terminalBackground, themeCursor: theme?.terminalCursor)
  }

  /// The legacy rules. Theme terminal colours only apply in dark mode.
  @MainActor
  static func legacy(isDark: Bool, themeBackground: NSColor?, themeCursor: NSColor?) -> ResolvedTerminalColors {
    let background: NSColor
    if isDark, let themeBackground {
      background = themeBackground
    } else if isDark {
      background = legacyDarkBackground
    } else {
      background = legacyLightBackground
    }
    let cursor = isDark ? (themeCursor ?? legacyCursor) : legacyCursor
    return ResolvedTerminalColors(
      background: background,
      foreground: isDark ? legacyDarkForeground : legacyLightForeground,
      cursor: cursor,
      selection: nil,
      ansi: nil,
      palette: nil
    )
  }

  /// What the running app uses: the new shell flag captured at launch and
  /// the active Workbench palette.
  @MainActor
  public static func current(isDark: Bool, theme: RuntimeTheme?) -> ResolvedTerminalColors {
    resolve(
      isDark: isDark,
      followsWorkbenchPalette: AppleShellLaunchFlag.isEnabled,
      palette: WorkbenchThemeRegistry.shared.palette(dark: isDark),
      theme: theme
    )
  }

  /// The terminal palette for the new shell, or nil in the legacy shell.
  /// Used by the Ghostty backend's appearance overlay.
  @MainActor
  public static func currentWorkbenchTerminalPalette(isDark: Bool) -> TerminalPalette? {
    guard AppleShellLaunchFlag.isEnabled else { return nil }
    return TerminalPalette(palette: WorkbenchThemeRegistry.shared.palette(dark: isDark), isDark: isDark)
  }
}

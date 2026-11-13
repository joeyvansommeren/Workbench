import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("TerminalPaletteResolver")
struct TerminalPaletteResolverTests {
  private static let palettes: [(name: String, palette: WorkbenchPalette, isDark: Bool)] = [
    ("Standard light", .appleLight, false),
    ("Standard dark", .appleDark, true),
    ("Warm light", .appleWarmLight, false),
    ("Warm dark", .appleWarmDark, true),
  ]

  // MARK: - New shell

  @Test("Light terminal: background is the light surfaceTerminal token")
  func lightBackgroundIsSurfaceTerminal() {
    let colors = TerminalPaletteResolver.resolve(
      isDark: false, followsWorkbenchPalette: true, palette: .appleLight, theme: nil)
    #expect(colors.palette?.background == WorkbenchPalette.appleLight.surfaceTerminal)
    #expect(Self.components(colors.background) == Self.components(WorkbenchPalette.appleLight.surfaceTerminal.nsColor))
    #expect(colors.palette?.foreground == WorkbenchPalette.appleLight.textPrimary)
    #expect(colors.palette?.cursor == WorkbenchPalette.appleLight.textPrimary)
  }

  @Test("Every palette has 16 ANSI slots, each at least 3:1 against the background")
  func ansiSlotsMeetContrast() {
    for entry in Self.palettes {
      let terminal = TerminalPalette(palette: entry.palette, isDark: entry.isDark)
      #expect(terminal.ansi.count == 16, "\(entry.name)")
      for (slot, color) in terminal.ansi.enumerated() {
        let ratio = color.contrastRatio(with: terminal.background)
        #expect(ratio >= 3, "\(entry.name) slot \(slot): \(ratio)")
      }
    }
  }

  @Test("Foreground is at least 4.5:1 against the background in every palette")
  func foregroundMeetsContrast() {
    for entry in Self.palettes {
      let terminal = TerminalPalette(palette: entry.palette, isDark: entry.isDark)
      let ratio = terminal.foreground.contrastRatio(with: terminal.background)
      #expect(ratio >= 4.5, "\(entry.name): \(ratio)")
    }
  }

  @Test("Token hues come straight from the palette when they already pass")
  func tokenHuesAreUsedAsIs() {
    let terminal = TerminalPalette(palette: .appleLight, isDark: false)
    #expect(terminal.ansi[1] == WorkbenchPalette.appleLight.ansiRed)
    #expect(terminal.ansi[2] == WorkbenchPalette.appleLight.ansiGreen)
    #expect(terminal.ansi[3] == WorkbenchPalette.appleLight.ansiOrange)
    #expect(terminal.ansi[4] == WorkbenchPalette.appleLight.ansiBlue)
  }

  @Test("Selection is the accent tint composited over the background (opaque)")
  func selectionIsOpaqueAccentTint() {
    let terminal = TerminalPalette(palette: .appleDark, isDark: true)
    #expect(terminal.selection.a == 1)
    #expect(terminal.selection == WorkbenchPalette.appleDark.accentTint.composited(over: terminal.background))
  }

  @Test("Palette switch changes the signature")
  func paletteSwitchChangesSignature() {
    let standard = TerminalPalette(palette: .appleLight, isDark: false)
    let warm = TerminalPalette(palette: .appleWarmLight, isDark: false)
    #expect(standard.signature != warm.signature)
  }

  @Test("New shell ignores YAML theme terminal colors")
  func newShellIgnoresTheme() {
    let colors = TerminalPaletteResolver.resolve(
      isDark: true, followsWorkbenchPalette: true, palette: .appleDark, theme: nil)
    #expect(colors.ansi?.count == 16)
    #expect(colors.selection != nil)
    #expect(Self.components(colors.background) == Self.components(WorkbenchPalette.appleDark.surfaceTerminal.nsColor))
  }

  // MARK: - Legacy (flag off)

  @Test("Flag off, dark without theme: legacy dark colors, ANSI untouched")
  func legacyDarkDefaults() {
    let colors = TerminalPaletteResolver.resolve(
      isDark: true, followsWorkbenchPalette: false, palette: .appleDark, theme: nil)
    #expect(Self.components(colors.background) == Self.components(NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)))
    #expect(Self.components(colors.foreground) == Self.components(NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1)))
    #expect(Self.components(colors.cursor) == Self.components(NSColor(red: 204 / 255, green: 120 / 255, blue: 92 / 255, alpha: 1)))
    #expect(colors.ansi == nil)
    #expect(colors.selection == nil)
    #expect(colors.palette == nil)
  }

  @Test("Flag off, dark with theme: theme background and cursor apply")
  func legacyDarkTheme() {
    let background = NSColor(srgbRed: 0.2, green: 0.1, blue: 0.3, alpha: 1)
    let cursor = NSColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1)
    let colors = TerminalPaletteResolver.legacy(isDark: true, themeBackground: background, themeCursor: cursor)
    #expect(colors.background === background)
    #expect(colors.cursor === cursor)
  }

  @Test("Flag off, light: theme colors never apply, legacy light background")
  func legacyLightIgnoresTheme() {
    let background = NSColor(srgbRed: 0.2, green: 0.1, blue: 0.3, alpha: 1)
    let cursor = NSColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1)
    let colors = TerminalPaletteResolver.legacy(isDark: false, themeBackground: background, themeCursor: cursor)
    #expect(Self.components(colors.background) == Self.components(NSColor(Color.backgroundLight)))
    #expect(Self.components(colors.foreground) == Self.components(NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
    #expect(Self.components(colors.cursor) == Self.components(NSColor(red: 204 / 255, green: 120 / 255, blue: 92 / 255, alpha: 1)))
    #expect(colors.ansi == nil)
  }

  // MARK: - Helpers

  private static func components(_ color: NSColor) -> [Int] {
    guard let rgb = color.usingColorSpace(.sRGB) else { return [] }
    return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
      .map { Int(($0 * 1000).rounded()) }
  }
}

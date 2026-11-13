import AppKit
import Foundation
import Testing

@testable import AgentHubCore

// MARK: - Palette parity with the CSS fixture

// Serialized: the registry is a shared singleton that also persists the choice.
@Suite("WorkbenchPalette", .serialized)
@MainActor
struct WorkbenchPaletteTests {

  // MARK: - Both appearances defined

  @Test("light and dark palettes are not equal (standard)")
  func lightAndDarkDiffer() {
    #expect(WorkbenchPalette.appleLight != WorkbenchPalette.appleDark)
  }

  @Test("light and dark palettes are not equal (warm)")
  func warmLightAndDarkDiffer() {
    #expect(WorkbenchPalette.appleWarmLight != WorkbenchPalette.appleWarmDark)
  }

  @Test("standard and warm light palettes differ")
  func standardAndWarmLightDiffer() {
    #expect(WorkbenchPalette.appleLight != WorkbenchPalette.appleWarmLight)
  }

  @Test("standard and warm dark palettes differ")
  func standardAndWarmDarkDiffer() {
    #expect(WorkbenchPalette.appleDark != WorkbenchPalette.appleWarmDark)
  }

  // MARK: - Standard spot-checks

  @Test("standard light surfaceWindow matches #F3F3F4")
  func lightSurfaceWindow() {
    assertHex(WorkbenchPalette.appleLight.surfaceWindow, "#F3F3F4")
  }

  @Test("standard light textPrimary matches #1D1D1F")
  func lightTextPrimary() {
    assertHex(WorkbenchPalette.appleLight.textPrimary, "#1D1D1F")
  }

  @Test("standard light accent matches #0A6CDC")
  func lightAccent() {
    assertHex(WorkbenchPalette.appleLight.accent, "#0A6CDC")
  }

  @Test("standard dark surfaceContent matches #1C1C1F")
  func darkSurfaceContent() {
    assertHex(WorkbenchPalette.appleDark.surfaceContent, "#1C1C1F")
  }

  @Test("standard dark textPrimary matches #F2F2F5")
  func darkTextPrimary() {
    assertHex(WorkbenchPalette.appleDark.textPrimary, "#F2F2F5")
  }

  @Test("standard dark accent matches #1F6FEB")
  func darkAccent() {
    assertHex(WorkbenchPalette.appleDark.accent, "#1F6FEB")
  }

  @Test("standard light linkUnderline is transparent")
  func standardLightLinkUnderline() {
    #expect(WorkbenchPalette.appleLight.linkUnderline.a == 0)
  }

  @Test("standard dark linkUnderline is transparent")
  func standardDarkLinkUnderline() {
    #expect(WorkbenchPalette.appleDark.linkUnderline.a == 0)
  }

  // MARK: - Warm spot-checks

  @Test("warm light surfaceWindow matches #F3F1EC")
  func warmLightSurfaceWindow() {
    assertHex(WorkbenchPalette.appleWarmLight.surfaceWindow, "#F3F1EC")
  }

  @Test("warm light accent matches #1C1917 (ink)")
  func warmLightAccent() {
    assertHex(WorkbenchPalette.appleWarmLight.accent, "#1C1917")
  }

  @Test("warm dark textPrimary matches #F3EEE8")
  func warmDarkTextPrimary() {
    assertHex(WorkbenchPalette.appleWarmDark.textPrimary, "#F3EEE8")
  }

  @Test("warm dark accent matches #F3EEE8 (ink)")
  func warmDarkAccent() {
    assertHex(WorkbenchPalette.appleWarmDark.accent, "#F3EEE8")
  }

  @Test("warm light linkUnderline is non-transparent")
  func warmLightLinkUnderline() {
    #expect(WorkbenchPalette.appleWarmLight.linkUnderline.a > 0)
    assertAlpha(WorkbenchPalette.appleWarmLight.linkUnderline, expected: 0.35)
  }

  @Test("warm dark linkUnderline is non-transparent")
  func warmDarkLinkUnderline() {
    #expect(WorkbenchPalette.appleWarmDark.linkUnderline.a > 0)
    assertAlpha(WorkbenchPalette.appleWarmDark.linkUnderline, expected: 0.4)
  }

  // MARK: - Alpha parity

  @Test("standard light surfaceOverlay has 0.96 alpha")
  func lightOverlayAlpha() {
    assertAlpha(WorkbenchPalette.appleLight.surfaceOverlay, expected: 0.96)
  }

  @Test("standard dark surfaceOverlay has 0.96 alpha")
  func darkOverlayAlpha() {
    assertAlpha(WorkbenchPalette.appleDark.surfaceOverlay, expected: 0.96)
  }

  @Test("warm light surfaceOverlay has 0.96 alpha")
  func warmLightOverlayAlpha() {
    assertAlpha(WorkbenchPalette.appleWarmLight.surfaceOverlay, expected: 0.96)
  }

  @Test("warm dark surfaceOverlay has 0.96 alpha")
  func warmDarkOverlayAlpha() {
    assertAlpha(WorkbenchPalette.appleWarmDark.surfaceOverlay, expected: 0.96)
  }

  // MARK: - Dynamic colour resolution

  @Test("dynamic NSColor resolves differently for light and dark")
  func dynamicResolution() {
    let light = NSAppearance(named: .aqua)!
    let dark = NSAppearance(named: .darkAqua)!

    let nsLight = NSColor.wbSurfaceContent
    let lightResolved = nsLight.resolvedColor(for: light)
    let darkResolved = nsLight.resolvedColor(for: dark)

    let lr = lightResolved.redComponent
    let dr = darkResolved.redComponent
    #expect(abs(lr - dr) > 0.1, "Light and dark resolved colours should differ")
  }

  // MARK: - WCAG >= 4.5 for all four modes

  @Test("Compositing blends a translucent colour over its base")
  func compositing() {
    let half = SRGBA(r: 1, g: 1, b: 1, a: 0.5).composited(over: SRGBA(r: 0, g: 0, b: 0))
    #expect(abs(half.r - 0.5) < 0.0001 && half.a == 1)
  }

  // Helper to run contrast checks on one palette
  private func assertTextContrast(_ p: WorkbenchPalette, label: String) {
    let pairs: [(String, SRGBA, SRGBA)] = [
      ("primary on content", p.textPrimary, p.surfaceContent),
      ("secondary on content", p.textSecondary, p.surfaceContent),
      ("tertiary on content", p.textTertiary, p.surfaceContent),
      ("primary on sidebar", p.textPrimary, p.surfaceSidebar),
    ]
    for (name, fg, bg) in pairs {
      // Composite translucent surfaces over the content panel, as they render.
      let base = bg.composited(over: p.surfaceContent)
      let ratio = fg.composited(over: base).contrastRatio(with: base)
      #expect(ratio >= 4.5, "\(label) \(name) WCAG AA: \(ratio)")
    }
  }

  private func assertStatusContrast(_ p: WorkbenchPalette, label: String) {
    let pairs: [(String, SRGBA, SRGBA)] = [
      ("working", p.statusWorkingText, p.statusWorkingTint),
      ("ready", p.statusReadyText, p.statusReadyTint),
      ("attention", p.statusAttentionText, p.statusAttentionTint),
      ("error", p.statusErrorText, p.statusErrorTint),
      ("idle", p.statusIdleText, p.statusIdleTint),
    ]
    for (name, fg, bg) in pairs {
      // Dark-mode tints are translucent (about 15%): blend over the content panel first.
      let tint = bg.composited(over: p.surfaceContent)
      let ratio = fg.composited(over: tint).contrastRatio(with: tint)
      #expect(ratio >= 4.5, "\(label) status \(name) WCAG AA: \(ratio)")
    }
  }

  @Test("WCAG >= 4.5 text pairs (standard light)")
  func contrastStandardLight() {
    assertTextContrast(.appleLight, label: "standard light")
  }

  @Test("WCAG >= 4.5 text pairs (standard dark)")
  func contrastStandardDark() {
    assertTextContrast(.appleDark, label: "standard dark")
  }

  @Test("WCAG >= 4.5 text pairs (warm light)")
  func contrastWarmLight() {
    assertTextContrast(.appleWarmLight, label: "warm light")
  }

  @Test("WCAG >= 4.5 text pairs (warm dark)")
  func contrastWarmDark() {
    assertTextContrast(.appleWarmDark, label: "warm dark")
  }

  @Test("WCAG >= 4.5 status text pairs (standard light)")
  func statusContrastStandardLight() {
    assertStatusContrast(.appleLight, label: "standard light")
  }

  @Test("WCAG >= 4.5 status text pairs (standard dark)")
  func statusContrastStandardDark() {
    assertStatusContrast(.appleDark, label: "standard dark")
  }

  @Test("WCAG >= 4.5 status text pairs (warm light)")
  func statusContrastWarmLight() {
    assertStatusContrast(.appleWarmLight, label: "warm light")
  }

  @Test("WCAG >= 4.5 status text pairs (warm dark)")
  func statusContrastWarmDark() {
    assertStatusContrast(.appleWarmDark, label: "warm dark")
  }

  // MARK: - Theme registry

  @Test("palette preference resolves to correct theme")
  func palettePreferenceResolution() {
    #expect(PalettePreference.standard.theme == .apple)
    #expect(PalettePreference.warm.theme == .appleWarm)
  }

  @Test("live palette switch changes the registry theme")
  func livePaletteSwitch() {
    let registry = WorkbenchThemeRegistry.shared
    // Start from a known state: the stored preference outlives a crashed run.
    registry.setPalette(.standard)
    let originalRevision = registry.revision
    defer { registry.setPalette(.standard) }

    registry.setPalette(.warm)
    #expect(registry.current.id == "appleWarm")
    #expect(registry.revision > originalRevision)

    registry.setPalette(.standard)
    #expect(registry.current.id == "apple")
  }

  @Test("live palette switch invalidates colour cache")
  func liveSwitchInvalidatesCache() {
    let registry = WorkbenchThemeRegistry.shared
    registry.setPalette(.standard)
    defer { registry.setPalette(.standard) }

    // Force a colour to be cached
    _ = NSColor.wbSurfaceWindow

    // Switch palette
    registry.setPalette(.warm)

    // After switch, the registry should be warm
    let palette = registry.palette(dark: false)
    assertHex(palette.surfaceWindow, "#F3F1EC")
  }

  @Test("palette(dark:) returns correct palette for warm")
  func warmPaletteResolution() {
    let registry = WorkbenchThemeRegistry.shared
    registry.setPalette(.standard)
    defer { registry.setPalette(.standard) }

    registry.setPalette(.warm)
    let light = registry.palette(dark: false)
    let dark = registry.palette(dark: true)
    #expect(light == WorkbenchPalette.appleWarmLight)
    #expect(dark == WorkbenchPalette.appleWarmDark)
  }

  // MARK: - Helpers

  private func assertHex(_ srgba: SRGBA, _ hex: String, tolerance: CGFloat = 1.0 / 255.0) {
    let expected = SRGBA(hex: hex)
    #expect(abs(srgba.r - expected.r) <= tolerance, "R mismatch for \(hex)")
    #expect(abs(srgba.g - expected.g) <= tolerance, "G mismatch for \(hex)")
    #expect(abs(srgba.b - expected.b) <= tolerance, "B mismatch for \(hex)")
  }

  private func assertAlpha(_ srgba: SRGBA, expected: CGFloat, tolerance: CGFloat = 0.005) {
    #expect(abs(srgba.a - expected) <= tolerance, "Alpha \(srgba.a) != \(expected)")
  }
}

// MARK: - NSColor resolution helper

extension NSColor {
  /// Resolve this dynamic colour under a specific appearance.
  fileprivate func resolvedColor(for appearance: NSAppearance) -> NSColor {
    var resolved: NSColor = self
    appearance.performAsCurrentDrawingAppearance {
      resolved = self.usingColorSpace(.sRGB) ?? self
    }
    return resolved
  }
}

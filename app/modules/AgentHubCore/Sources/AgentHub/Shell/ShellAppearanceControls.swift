//
//  ShellAppearanceControls.swift
//  AgentHub
//
//  The title row's Standard | Warm switch (`#palette-switch`) and light/dark
//  button (`#toggle-theme`). Both go through `WorkbenchAppearanceController`
//  and read the same stored values as Settings › Appearance and the palette,
//  so all three stay in step.
//

import AppKit
import SwiftUI

struct ShellPaletteSwitch: View {
  @AppStorage(AgentHubDefaults.palette) private var paletteRaw = PalettePreference.standard.rawValue

  var body: some View {
    WorkbenchSegmentedControl(
      selection: Binding(
        get: { PalettePreference(rawValue: paletteRaw) ?? .standard },
        set: { palette in
          MainThreadStallMonitor.breadcrumb("palette: \(palette.rawValue)")
          // One window crossfade instead of a repaint cut (motion plan item 13).
          ThemeCrossfade.perform(in: NSApp.keyWindow) {
            WorkbenchAppearanceController.selectPalette(palette)
          }
        }
      ),
      accessibilityIdentifier: "shell.palette"
    )
    .fixedSize()
    .accessibilityLabel("Palette")
  }
}

/// Moon in light, sun in dark. Toggles between explicit Light and Dark; from
/// System it goes to the opposite of what shows now.
struct ShellAppearanceButton: View {
  @Environment(\.colorScheme) private var colorScheme

  private var isDark: Bool { colorScheme == .dark }

  var body: some View {
    let label = isDark ? "Switch to light appearance" : "Switch to dark appearance"
    IconButton(
      systemImage: isDark ? "sun.max" : "moon",
      accessibilityLabel: label,
      accessibilityIdentifier: "shell.toggleAppearance"
    ) {
      let next = WorkbenchAppearanceController.toggledAppearance(currentlyDark: isDark)
      MainThreadStallMonitor.breadcrumb("appearance: \(next.rawValue)")
      // One window crossfade instead of a brightness cut (motion plan item 13).
      ThemeCrossfade.perform(in: NSApp.keyWindow) {
        WorkbenchAppearanceController.selectAppearance(next)
      }
    }
    .help(label)
  }
}

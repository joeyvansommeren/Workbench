//
//  WorkbenchAppearanceSettingsSection.swift
//  AgentHub
//
//  Settings › Appearance for the new shell: Appearance (System / Light / Dark)
//  and Palette (Standard / Warm). Both apply live. Replaces the YAML theme
//  picker, which only the legacy shell shows.
//

import SwiftUI

extension AppearancePreference: CustomStringConvertible {
  public var description: String { displayName }
}

extension PalettePreference: CustomStringConvertible {
  public var description: String { displayName }
}

struct WorkbenchAppearanceSettingsSection: View {
  // Backed by the stored values, so a change made elsewhere (the palette's
  // "Switch appearance") shows here too.
  @AppStorage(AgentHubDefaults.appearance) private var appearanceRaw = AppearancePreference.system.rawValue
  @AppStorage(AgentHubDefaults.palette) private var paletteRaw = PalettePreference.defaultPalette.rawValue

  var body: some View {
    Section("Appearance") {
      LabeledContent("Appearance") {
        WorkbenchSegmentedControl(
          selection: Binding(
            get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
            set: { WorkbenchAppearanceController.selectAppearance($0) }
          ),
          accessibilityLabel: "Appearance",
          accessibilityIdentifier: "settings.appearance"
        )
        .fixedSize()
      }
      LabeledContent("Palette") {
        WorkbenchSegmentedControl(
          selection: Binding(
            get: { PalettePreference(rawValue: paletteRaw) ?? .defaultPalette },
            set: { WorkbenchAppearanceController.selectPalette($0) }
          ),
          accessibilityLabel: "Palette",
          accessibilityIdentifier: "settings.palette"
        )
        .fixedSize()
      }
    }
  }
}

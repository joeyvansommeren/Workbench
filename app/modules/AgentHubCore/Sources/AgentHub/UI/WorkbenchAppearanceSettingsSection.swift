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
  @State private var appearance = WorkbenchAppearanceController.storedAppearance()
  @State private var palette = WorkbenchAppearanceController.storedPalette()

  var body: some View {
    Section("Appearance") {
      LabeledContent("Appearance") {
        WorkbenchSegmentedControl(
          selection: Binding(
            get: { appearance },
            set: { newValue in
              appearance = newValue
              WorkbenchAppearanceController.selectAppearance(newValue)
            }
          ),
          accessibilityIdentifier: "settings.appearance"
        )
        .fixedSize()
      }
      LabeledContent("Palette") {
        WorkbenchSegmentedControl(
          selection: Binding(
            get: { palette },
            set: { newValue in
              palette = newValue
              WorkbenchAppearanceController.selectPalette(newValue)
            }
          ),
          accessibilityIdentifier: "settings.palette"
        )
        .fixedSize()
      }
    }
  }
}

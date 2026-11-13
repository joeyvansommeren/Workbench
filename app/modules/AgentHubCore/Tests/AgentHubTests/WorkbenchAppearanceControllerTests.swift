import AppKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Workbench appearance and palette settings")
struct WorkbenchAppearanceControllerTests {
  private final class FakeAppearanceTarget: AppearanceApplying {
    var appearance: NSAppearance?
  }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "WorkbenchAppearanceControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test(
    "A stored appearance maps to the NSAppearance applied at launch",
    arguments: [
      ("system", nil),
      ("light", "NSAppearanceNameAqua"),
      ("dark", "NSAppearanceNameDarkAqua"),
      ("bogus", nil),
    ] as [(String, String?)]
  )
  func storedAppearanceApplies(raw: String, expectedName: String?) {
    let expected = expectedName.map(NSAppearance.Name.init(rawValue:))
    let defaults = makeDefaults()
    defaults.set(raw, forKey: AgentHubDefaults.appearance)
    let target = FakeAppearanceTarget()
    target.appearance = NSAppearance(named: .vibrantDark)

    WorkbenchAppearanceController.applyStoredAppearance(defaults: defaults, to: target)

    #expect(target.appearance?.name == expected)
  }

  @Test("Nothing stored follows the system")
  func defaultIsSystem() {
    let defaults = makeDefaults()
    #expect(WorkbenchAppearanceController.storedAppearance(defaults: defaults) == .system)
    #expect(WorkbenchAppearanceController.storedPalette(defaults: defaults) == .standard)
  }

  @Test("Selecting an appearance persists it and applies it at once")
  func selectAppearance() {
    let defaults = makeDefaults()
    let target = FakeAppearanceTarget()

    WorkbenchAppearanceController.selectAppearance(.dark, defaults: defaults, to: target)
    #expect(defaults.string(forKey: AgentHubDefaults.appearance) == "dark")
    #expect(target.appearance?.name == .darkAqua)

    WorkbenchAppearanceController.selectAppearance(.system, defaults: defaults, to: target)
    #expect(defaults.string(forKey: AgentHubDefaults.appearance) == "system")
    #expect(target.appearance == nil)
  }

  @Test("A stored palette maps to its theme")
  func storedPaletteMapsToTheme() {
    let defaults = makeDefaults()
    defaults.set("warm", forKey: AgentHubDefaults.palette)
    #expect(WorkbenchAppearanceController.storedPalette(defaults: defaults).theme == .appleWarm)
    defaults.set("standard", forKey: AgentHubDefaults.palette)
    #expect(WorkbenchAppearanceController.storedPalette(defaults: defaults).theme == .apple)
  }

  @Test("Selecting a palette switches the registry live and bumps its revision")
  func selectPaletteSwitchesLive() {
    let registry = WorkbenchThemeRegistry.shared
    let original = registry.current
    let originalStored = UserDefaults.standard.string(forKey: AgentHubDefaults.palette)
    defer {
      registry.setCurrent(original)
      if let originalStored {
        UserDefaults.standard.set(originalStored, forKey: AgentHubDefaults.palette)
      } else {
        UserDefaults.standard.removeObject(forKey: AgentHubDefaults.palette)
      }
    }

    registry.setCurrent(.apple)
    let revision = registry.revision
    WorkbenchAppearanceController.selectPalette(.warm)
    #expect(registry.current == .appleWarm)
    #expect(registry.revision == revision + 1)
    #expect(WorkbenchAppearanceController.storedPalette() == .warm)

    WorkbenchAppearanceController.selectPalette(.standard)
    #expect(registry.current == .apple)
  }

  @Test("Switch appearance picks the explicit opposite")
  func toggle() {
    #expect(WorkbenchAppearanceController.toggledAppearance(currentlyDark: true) == .light)
    #expect(WorkbenchAppearanceController.toggledAppearance(currentlyDark: false) == .dark)
  }

  @Test("Appearance and palette segments use the display names")
  func segmentLabels() {
    #expect(AppearancePreference.allCases.map(\.description) == ["System", "Light", "Dark"])
    #expect(PalettePreference.allCases.map(\.description) == ["Standard", "Warm"])
  }
}

import AppKit
import Foundation
import Testing

@testable import AgentHub

@Suite("AppearancePreference")
struct AppearancePreferenceTests {

  @Test("system maps to nil NSAppearance.Name")
  func systemMapsToNil() {
    #expect(AppearancePreference.system.nsAppearanceName == nil)
  }

  @Test("light maps to .aqua")
  func lightMapsToAqua() {
    #expect(AppearancePreference.light.nsAppearanceName == .aqua)
  }

  @Test("dark maps to .darkAqua")
  func darkMapsToDarkAqua() {
    #expect(AppearancePreference.dark.nsAppearanceName == .darkAqua)
  }

  @Test("all cases have a display name")
  func displayNames() {
    for pref in AppearancePreference.allCases {
      #expect(!pref.displayName.isEmpty)
    }
  }

  @Test("raw value round-trips")
  func rawValueRoundTrip() {
    for pref in AppearancePreference.allCases {
      let recovered = AppearancePreference(rawValue: pref.rawValue)
      #expect(recovered == pref)
    }
  }

  @Test("unknown raw value defaults to system via fromDefaults")
  func unknownDefaultsToSystem() {
    let defaults = UserDefaults.standard
    let key = AgentHubDefaults.appearance
    let oldValue = defaults.string(forKey: key)
    defer {
      if let old = oldValue {
        defaults.set(old, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
    defaults.set("bogus", forKey: key)
    #expect(AppearancePreference.fromDefaults() == .system)
  }

  @Test("defaults key is correctly namespaced")
  func keyNamespace() {
    #expect(AgentHubDefaults.appearance.hasPrefix("com.agenthub."))
  }

  @Test("appleShellEnabled key is correctly namespaced")
  func appleShellKey() {
    #expect(AgentHubDefaults.appleShellEnabled.hasPrefix("com.agenthub.features."))
  }

  @Test("palette key is correctly namespaced")
  func paletteKey() {
    #expect(AgentHubDefaults.palette.hasPrefix("com.agenthub."))
  }

  @Test("palette preference round-trips")
  func paletteRoundTrip() {
    for pref in PalettePreference.allCases {
      let recovered = PalettePreference(rawValue: pref.rawValue)
      #expect(recovered == pref)
    }
  }

  @Test("palette preference defaults to standard")
  func paletteDefaultsToStandard() {
    let defaults = UserDefaults.standard
    let key = AgentHubDefaults.palette
    let oldValue = defaults.string(forKey: key)
    defer {
      if let old = oldValue {
        defaults.set(old, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
    defaults.removeObject(forKey: key)
    #expect(PalettePreference.fromDefaults() == .standard)
  }
}

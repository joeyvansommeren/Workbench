import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Keyboard navigation setting")
struct KeyboardNavigationSettingTests {
  @Test("Starts from the system value and follows it on refresh")
  func followsSetting() {
    var isOn = false
    let setting = KeyboardNavigationSetting(read: { isOn })
    #expect(!setting.isEnabled)

    isOn = true
    setting.refresh()
    #expect(setting.isEnabled)

    isOn = false
    setting.refresh()
    #expect(!setting.isEnabled)
  }
}

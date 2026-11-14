import Testing

@testable import AgentHubCore

@Suite("KeyCaps split")
struct KeyCapsSplitTests {

  @Test("modifier glyphs each get a cap, the key gets one")
  func modifiersThenKey() {
    #expect(KeyCaps.split("⌘K") == ["⌘", "K"])
    #expect(KeyCaps.split("⌃⌥⇧S") == ["⌃", "⌥", "⇧", "S"])
  }

  @Test("a multi-letter key stays one cap")
  func wordKey() {
    #expect(KeyCaps.split("Esc") == ["Esc"])
    #expect(KeyCaps.split("⌃⌥Space") == ["⌃", "⌥", "Space"])
  }

  @Test("modifiers only, and empty")
  func edgeCases() {
    #expect(KeyCaps.split("⌘") == ["⌘"])
    #expect(KeyCaps.split("").isEmpty)
  }
}

import Testing

@testable import AgentHubCore

/// Hover and press feedback for the small buttons inside FilterChip,
/// FiltersButton and ErrorBanner (colour only, no scale).
@Suite("WB inline button feedback")
struct WBInlineButtonFeedbackTests {
  @Test("at rest: no fill, label secondary")
  func rest() {
    let feedback = WBInlineButtonFeedback.resolve(
      isEnabled: true, isHovered: false, isPressed: false, hoverFill: true)
    #expect(feedback == WBInlineButtonFeedback(showsHoverFill: false, showsPressedFill: false, emphasisesLabel: false))
  }

  @Test("hover: fill and primary label")
  func hover() {
    let feedback = WBInlineButtonFeedback.resolve(
      isEnabled: true, isHovered: true, isPressed: false, hoverFill: true)
    #expect(feedback == WBInlineButtonFeedback(showsHoverFill: true, showsPressedFill: false, emphasisesLabel: true))
  }

  @Test("press keeps the hover fill under the pressed fill")
  func press() {
    let feedback = WBInlineButtonFeedback.resolve(
      isEnabled: true, isHovered: false, isPressed: true, hoverFill: true)
    #expect(feedback == WBInlineButtonFeedback(showsHoverFill: true, showsPressedFill: true, emphasisesLabel: true))
  }

  @Test("chip remove: hover changes colour only, press adds the pressed fill")
  func colourOnlyHover() {
    let hover = WBInlineButtonFeedback.resolve(
      isEnabled: true, isHovered: true, isPressed: false, hoverFill: false)
    #expect(hover == WBInlineButtonFeedback(showsHoverFill: false, showsPressedFill: false, emphasisesLabel: true))
    let press = WBInlineButtonFeedback.resolve(
      isEnabled: true, isHovered: true, isPressed: true, hoverFill: false)
    #expect(press.showsPressedFill)
    #expect(!press.showsHoverFill)
  }

  @Test("disabled shows no hover or press")
  func disabled() {
    let feedback = WBInlineButtonFeedback.resolve(
      isEnabled: false, isHovered: true, isPressed: true, hoverFill: true)
    #expect(feedback == WBInlineButtonFeedback(showsHoverFill: false, showsPressedFill: false, emphasisesLabel: false))
  }
}

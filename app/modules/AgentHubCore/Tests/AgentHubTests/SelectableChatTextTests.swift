import AppKit
import Testing
@testable import AgentHubCore

@MainActor
@Suite("Selectable chat text")
struct SelectableChatTextTests {
  @Test func preservesSelectionOnUnchangedUpdates() {
    let view = NSTextView()
    let content = SelectableChatText(text: "Select only this fragment").attributedText
    SelectableChatText.update(view, content: content)
    view.setSelectedRange(NSRange(location: 12, length: 4))
    SelectableChatText.update(view, content: content)
    #expect(view.selectedRange() == NSRange(location: 12, length: 4))
    #expect((view.string as NSString).substring(with: view.selectedRange()) == "this")
  }

  @Test func preservesMarkdownTextAndLinksAndLiteralCode() {
    let content = SelectableChatText(text: "**Hello** [site](https://example.com)", markdown: true).attributedText
    #expect(content.string == "Hello site")
    #expect(content.attribute(.link, at: 6, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    let font = content.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    #expect(SelectableChatText(text: "**literal**", monospaced: true).attributedText.string == "**literal**")
  }
}

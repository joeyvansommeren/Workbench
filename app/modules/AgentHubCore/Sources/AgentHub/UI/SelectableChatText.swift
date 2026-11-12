import AppKit
import SwiftUI

/// Native selection without SwiftUI's text-selection overlay relaying out chat rows.
struct SelectableChatText: NSViewRepresentable {
  let text: String
  var markdown = false
  var monospaced = false
  var bold = false

  func makeNSView(context: Context) -> NSTextView {
    let view = NSTextView()
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.textContainer?.widthTracksTextView = true
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateNSView(_ view: NSTextView, context: Context) {
    Self.update(view, content: attributedText)
  }

  static func update(_ view: NSTextView, content: NSAttributedString) {
    // Unchanged streamed updates must preserve selection and avoid new layout.
    guard view.attributedString() != content else { return }
    view.textStorage?.setAttributedString(content)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0,
      let container = nsView.textContainer, let layout = nsView.layoutManager
    else { return nil }
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    return CGSize(width: width, height: max(18, ceil(layout.usedRect(for: container).height)))
  }

  var attributedText: NSAttributedString {
    let parsed = markdown ? ChatMarkdownText.inline(text) : AttributedString(text)
    let result = NSMutableAttributedString(string: String(parsed.characters))
    let font = monospaced
      ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
      : NSFont.systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    result.addAttributes([.font: font, .foregroundColor: NSColor.labelColor,
                          .paragraphStyle: paragraph], range: NSRange(location: 0, length: result.length))
    var offset = 0
    for run in parsed.runs {
      let length = String(parsed[run.range].characters).utf16.count
      let range = NSRange(location: offset, length: length)
      var runFont = font
      if let intent = run.inlinePresentationIntent {
        if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: 12, weight: .regular) }
        if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
        if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
      }
      result.addAttribute(.font, value: runFont, range: range)
      if let link = run.link { result.addAttribute(.link, value: link, range: range) }
      offset += length
    }
    return result
  }
}

import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
struct SessionAttentionQueueLayoutTests {
  @Test func rowsFitTheSidebarWithLongTitlesAndReasons() {
    let item = SessionAttentionItem(
      id: "test", title: String(repeating: "A long task name ", count: 8),
      reason: String(repeating: "Permission needed to run a command. ", count: 4))
    for width in [240.0, 288.0] {
      let host = NSHostingView(
        rootView: SessionAttentionQueueRow(
          item: item,
          isSelected: true, hasResult: true, onOpen: {}, onResult: {}
        )
        .frame(width: width))
      host.layoutSubtreeIfNeeded()
      #expect(host.fittingSize.width <= width)
      #expect(host.fittingSize.height.isFinite && host.fittingSize.height > 0)
    }
  }
}

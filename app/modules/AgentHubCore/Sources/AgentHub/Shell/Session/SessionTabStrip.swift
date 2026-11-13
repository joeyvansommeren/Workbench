//
//  SessionTabStrip.swift
//  AgentHub
//
//  The toolbar's session tabs (`.tabs` + `#new-tab` in the prototype). Tabs
//  flex between 120 and 204 pt. What does not fit at 120 pt goes into a
//  trailing chevron menu; the strip never scrolls.
//
//  Layout-loop safety: the strip's own width comes from its parent (it fills
//  the toolbar's leading slot) and never from its content, so measuring it
//  cannot feed back. The measured width is rounded to whole points and only
//  stored when it changes.
//

import SwiftUI

struct SessionTabStrip: View {
  let tabs: [SessionTabPresentation]
  let selectedID: String?
  let onSelect: (String) -> Void
  let onClose: (String) -> Void
  let onNewSession: () -> Void

  @State private var stripWidth = 0

  var body: some View {
    let layout = SessionTabsModel.layout(
      tabIDs: tabs.map(\.id),
      selectedID: selectedID,
      capacity: capacity
    )
    HStack(spacing: SessionTabMetrics.spacing) {
      HStack(spacing: SessionTabMetrics.spacing) {
        ForEach(layout.visible, id: \.self) { id in
          if let tab = tabs.first(where: { $0.id == id }) {
            SessionTab(
              presentation: tab,
              isSelected: tab.id == selectedID,
              onSelect: { onSelect(tab.id) },
              onClose: { onClose(tab.id) }
            )
          }
        }
      }
      if !layout.overflow.isEmpty {
        overflowMenu(layout.overflow)
      }
      IconButton(
        systemImage: "plus",
        accessibilityLabel: "New session",
        accessibilityIdentifier: "shell.newSession",
        action: onNewSession
      )
      .help("New session  ⌘N")
      Spacer(minLength: 0)
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: Int.self) { proxy in
      Int(proxy.size.width.rounded(.down))
    } action: { width in
      if width != stripWidth { stripWidth = width }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Open sessions")
  }

  /// Tabs that fit at their minimum width, leaving room for "+" and, when
  /// needed, the overflow chevron.
  private var capacity: Int {
    let spacing = SessionTabMetrics.spacing
    let button = SessionTabMetrics.trailingButtonWidth + spacing
    let all = SessionTabsModel.capacity(
      forWidth: CGFloat(stripWidth) - button,
      minimumTabWidth: SessionTabMetrics.minWidth,
      spacing: spacing
    )
    if tabs.count <= all { return all }
    return SessionTabsModel.capacity(
      forWidth: CGFloat(stripWidth) - 2 * button,
      minimumTabWidth: SessionTabMetrics.minWidth,
      spacing: spacing
    )
  }

  private func overflowMenu(_ ids: [String]) -> some View {
    Menu {
      ForEach(ids, id: \.self) { id in
        if let tab = tabs.first(where: { $0.id == id }) {
          Button(tab.title) { onSelect(tab.id) }
        }
      }
    } label: {
      Image(systemName: "chevron.down")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: SessionTabMetrics.trailingButtonWidth, height: DesignTokens.Size.control)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .foregroundStyle(Color.wbTextSecondary)
    .accessibilityLabel("\(ids.count) more tabs")
    .help("More tabs")
  }
}

//
//  ContentPanel.swift
//  AgentHub
//
//  The rounded content panel that sits on `surfaceWindow`, matching
//  `.panel` in the prototype: inset 8 from the window edge (no leading inset
//  while the sidebar is shown), radius 14, panel elevation.
//

import SwiftUI

struct ContentPanel<Content: View>: View {
  let isSidebarVisible: Bool
  @ViewBuilder let content: Content

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.Radius.container, style: .continuous)
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.wbSurfaceContent)
      .clipShape(shape)
      .wbElevation(.panel)
      .padding(.leading, isSidebarVisible ? 0 : DesignTokens.Inset.panel)
      .padding([.trailing, .bottom], DesignTokens.Inset.panel)
  }
}

//
//  MenuSurface.swift
//  AgentHub
//
//  Matches `.overlay-surface` and `.menu` in the prototype.
//

import SwiftUI

/// A blurred overlay surface for menus, popovers and sheets.
public struct MenuSurface<Content: View>: View {
  let width: CGFloat
  @ViewBuilder let content: () -> Content

  public init(width: CGFloat = DesignTokens.Width.popover, @ViewBuilder content: @escaping () -> Content) {
    self.width = width
    self.content = content
  }

  public var body: some View {
    VStack(spacing: 0) {
      content()
    }
    .padding(DesignTokens.Inset.container)
    .frame(width: width)
    .background {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.container)
        .fill(.ultraThinMaterial)
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.container)
            .fill(Color.wbSurfaceOverlay)
        }
    }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.container))
    .wbElevation(.overlay)
  }
}

//
//  View+PaletteChange.swift
//  AgentHub
//
//  View modifier that forces a redraw when the palette changes.
//  Window roots must apply `.wbRedrawsOnPaletteChange()` so that a
//  live palette switch invalidates cached colour values in the view tree.
//

import SwiftUI

extension View {
  /// Forces this subtree to redraw when `WorkbenchThemeRegistry.revision`
  /// changes. Apply on the content below a window's root — keep palette
  /// pickers outside the keyed subtree so they are not destroyed on switch.
  public func wbRedrawsOnPaletteChange() -> some View {
    modifier(PaletteChangeModifier())
  }
}

private struct PaletteChangeModifier: ViewModifier {
  @MainActor private var revision: Int {
    WorkbenchThemeRegistry.shared.revision
  }

  func body(content: Content) -> some View {
    content
      .id(WorkbenchThemeRegistry.shared.revision)
  }
}

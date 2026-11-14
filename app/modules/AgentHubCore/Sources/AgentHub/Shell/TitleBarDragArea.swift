//
//  TitleBarDragArea.swift
//  AgentHub
//
//  The new shell draws its own title band (height from
//  `ShellTitleBarMetrics`; no NSToolbar, see Shell/README.md). Put this
//  behind that band so its empty space acts like a real title bar: drag
//  moves the window, and a double-click follows the user's "double-click a
//  window's title bar to" setting.
//

import AppKit
import SwiftUI

enum TitleBarDoubleClickAction: Equatable {
  case zoom
  case minimize
  case none

  /// Maps the global `AppleActionOnDoubleClick` value. Unset or unknown
  /// values zoom, which is the system default.
  static func from(preference: String?) -> TitleBarDoubleClickAction {
    switch preference {
    case "Minimize": return .minimize
    case "None": return .none
    default: return .zoom
    }
  }
}

struct TitleBarDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> TitleBarDragView { TitleBarDragView() }
  func updateNSView(_ nsView: TitleBarDragView, context: Context) {}
}

final class TitleBarDragView: NSView {
  /// The user's `AppleActionOnDoubleClick` value. Tests replace it, so the
  /// result never depends on the machine's global setting.
  var doubleClickPreference: () -> String? = {
    UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
  }

  override var mouseDownCanMoveWindow: Bool { true }

  // Like a real title bar: the first click on an inactive window already
  // drags it, and a double-click zooms it.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    guard event.clickCount == 2 else {
      window.performDrag(with: event)
      return
    }
    switch TitleBarDoubleClickAction.from(preference: doubleClickPreference()) {
    case .zoom: window.performZoom(nil)
    case .minimize: window.performMiniaturize(nil)
    case .none: break
    }
  }
}

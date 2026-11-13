//
//  TitleBarDragArea.swift
//  AgentHub
//
//  The new shell draws its own 52 pt title row (no NSToolbar, see
//  Shell/README.md). Put this behind that row so its empty space acts like a
//  real title bar: drag moves the window, and a double-click follows the
//  user's "double-click a window's title bar to" setting.
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
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    guard event.clickCount == 2 else {
      window.performDrag(with: event)
      return
    }
    let preference = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
    switch TitleBarDoubleClickAction.from(preference: preference) {
    case .zoom: window.performZoom(nil)
    case .minimize: window.performMiniaturize(nil)
    case .none: break
    }
  }
}

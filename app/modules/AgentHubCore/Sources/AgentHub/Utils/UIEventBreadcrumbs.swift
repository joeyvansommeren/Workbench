//
//  UIEventBreadcrumbs.swift
//  AgentHub
//
//  Feeds `MainThreadStallMonitor` with the user and window events that can
//  start a SwiftUI/AppKit layout loop: double-clicks, window resizes and zooms,
//  display changes and full screen. A loop freezes the main thread for seconds
//  before AppKit throws, so the stall report names its trigger.
//  See CLAUDE.md › "Layout-loop crash".
//

import AppKit

@MainActor
public enum UIEventBreadcrumbs {
  private static var isInstalled = false
  private static var mouseMonitor: Any?
  private static var observers: [NSObjectProtocol] = []
  private static var lastResizeBreadcrumbAt = Date.distantPast

  /// Programmatic resizes (zoom, display changes) animate through many frames;
  /// one breadcrumb per burst is enough.
  nonisolated static let resizeBreadcrumbInterval: TimeInterval = 0.25

  public static func install() {
    guard !isInstalled else { return }
    isInstalled = true

    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
      if event.clickCount >= 2 {
        let text = MainActor.assumeIsolated { describeDoubleClick(event) }
        MainThreadStallMonitor.breadcrumb(text)
      }
      return event
    }

    let center = NotificationCenter.default
    let windowEvents: [(Notification.Name, String)] = [
      (NSWindow.didEndLiveResizeNotification, "window resized by dragging"),
      (NSWindow.didChangeScreenNotification, "window moved to another display"),
      (NSWindow.didChangeBackingPropertiesNotification, "window scale changed"),
      (NSWindow.didEnterFullScreenNotification, "window entered full screen"),
      (NSWindow.didExitFullScreenNotification, "window left full screen"),
    ]
    for (name, label) in windowEvents {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
        let size = MainActor.assumeIsolated { (note.object as? NSWindow)?.frame.size }
        MainThreadStallMonitor.breadcrumb(windowBreadcrumb(label, size: size))
      })
    }

    // Zoom and display changes resize without a live resize.
    observers.append(center.addObserver(
      forName: NSWindow.didResizeNotification, object: nil, queue: .main
    ) { note in
      MainActor.assumeIsolated {
        guard let window = note.object as? NSWindow, !window.inLiveResize else { return }
        let now = Date()
        guard now.timeIntervalSince(lastResizeBreadcrumbAt) >= resizeBreadcrumbInterval else { return }
        lastResizeBreadcrumbAt = now
        MainThreadStallMonitor.breadcrumb(windowBreadcrumb("window resized (zoom or display)", size: window.frame.size))
      }
    })

    observers.append(center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
      MainThreadStallMonitor.breadcrumb("displays changed: \(NSScreen.screens.count) connected")
    })
  }

  private static func describeDoubleClick(_ event: NSEvent) -> String {
    guard let window = event.window, let contentView = window.contentView else {
      return "double-click outside a window"
    }
    let point = event.locationInWindow
    // The theme frame has no superview, so its hit test takes window coordinates.
    let hitView = (contentView.superview ?? contentView).hitTest(point)
    let titleBarHeight = window.frame.height - window.contentLayoutRect.maxY
    return doubleClickBreadcrumb(
      hitViewClass: hitView.map { String(describing: type(of: $0)) },
      parentClass: hitView?.superview.map { String(describing: type(of: $0)) },
      x: point.x,
      distanceFromTop: window.frame.height - point.y,
      titleBarHeight: titleBarHeight
    )
  }

  nonisolated static func doubleClickBreadcrumb(
    hitViewClass: String?,
    parentClass: String?,
    x: CGFloat,
    distanceFromTop: CGFloat,
    titleBarHeight: CGFloat
  ) -> String {
    let area = distanceFromTop <= titleBarHeight ? "title bar" : "content"
    let target = [hitViewClass, parentClass].compactMap { $0 }.joined(separator: " in ")
    return "double-click in \(area) on \(target.isEmpty ? "nothing" : target)"
      + " at x \(Int(x.rounded())), \(Int(distanceFromTop.rounded())) pt from top"
  }

  nonisolated static func windowBreadcrumb(_ label: String, size: CGSize?) -> String {
    guard let size else { return label }
    return "\(label): \(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
  }
}

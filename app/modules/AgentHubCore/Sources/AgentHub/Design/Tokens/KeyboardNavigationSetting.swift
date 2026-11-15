//
//  KeyboardNavigationSetting.swift
//  AgentHub
//
//  Whether macOS keyboard navigation is on (System Settings > Keyboard >
//  Keyboard navigation). macOS draws its own focus rings only then, so
//  `wbFocusRing` follows the same rule: no ring after a click, or when AppKit
//  picks a first responder on its own at launch.
//

import AppKit
import Observation

/// Observable mirror of `NSApplication.isFullKeyboardAccessEnabled`. No
/// polling: it reads the setting again when the system says it changed, and
/// when the app becomes active (the user changes it in System Settings).
@MainActor
@Observable
public final class KeyboardNavigationSetting {
  public static let shared = KeyboardNavigationSetting()

  public private(set) var isEnabled: Bool

  @ObservationIgnored private let read: @MainActor () -> Bool
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  /// - Parameter read: The setting's source; tests pass their own.
  init(read: @escaping @MainActor () -> Bool = { NSApplication.shared.isFullKeyboardAccessEnabled }) {
    self.read = read
    isEnabled = read()
    observers = [
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.KeyboardUIModeDidChange"), object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      },
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      },
    ]
  }

  /// Reads the setting again. Writes only on a change, so views that read
  /// `isEnabled` redraw only then.
  func refresh() {
    let value = read()
    if value != isEnabled { isEnabled = value }
  }
}

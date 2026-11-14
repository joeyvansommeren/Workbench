//
//  PanelEntrance.swift
//  AgentHub
//
//  Shared entrance for trailing panels (Sessions side panel, Reviews detail,
//  Sprint detail). The panel takes its final width in the same frame; only its
//  contents fade in and slide 8 pt from the trailing edge. No frame changes,
//  so it never drives a constraint pass outside its own subtree, and the
//  terminal NSView next to the side panel resizes once, not every frame.
//  Hiding is instant. Motion plan item 6.
//

import AppKit
import SwiftUI

/// Remembers that a panel was opened by the user, so only that appearance
/// animates. A panel that remounts because the selection changed (the session
/// detail is keyed by session id) must appear in place: selection is instant.
struct PanelEntranceGate: Equatable {
  private(set) var isPending = false

  /// The panel went from hidden to shown.
  mutating func panelOpened() { isPending = true }

  /// The panel was hidden before it appeared: nothing to animate.
  mutating func panelClosed() { isPending = false }

  /// Called once when the panel appears. True when this appearance is the
  /// open the user asked for.
  mutating func consume() -> Bool {
    defer { isPending = false }
    return isPending
  }
}

/// Distances and the timing used by `wbPanelEntrance`.
enum PanelEntranceMotion {
  /// Contents start this far toward the trailing edge the panel lives on.
  static let offset: CGFloat = 8
  /// Ease-out entrance, about 240 ms.
  static let animation: Animation = DesignTokens.Motion.medium

  /// The start state for a panel that mounts now: hidden only when it will
  /// animate. Under Reduce Motion the panel is at full opacity in place.
  static func startsHidden(animates: Bool, reduceMotion: Bool) -> Bool {
    animates && !reduceMotion
  }
}

private struct PanelEntranceModifier: ViewModifier {
  let onAppearConsume: () -> Bool

  @State private var isShown: Bool

  init(animates: Bool, onAppearConsume: @escaping () -> Bool) {
    self.onAppearConsume = onAppearConsume
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    _isShown = State(
      initialValue: !PanelEntranceMotion.startsHidden(animates: animates, reduceMotion: reduceMotion))
  }

  func body(content: Content) -> some View {
    content
      .opacity(isShown ? 1 : 0)
      .offset(x: isShown ? 0 : PanelEntranceMotion.offset)
      .onAppear {
        // Consume the gate even when the start state is already shown.
        let animates = onAppearConsume()
        guard !isShown else { return }
        if animates {
          withAnimation(.wbAnimation(PanelEntranceMotion.animation)) { isShown = true }
        } else {
          isShown = true
        }
      }
  }
}

/// Records, in the view that hosts a detail panel, whether the panel's
/// selection was empty at some point while this view was on screen. Only then
/// is the next open the user's own; a remount (⌘2/3/4, launch with a restored
/// selection, data that loads late) shows the panel in place.
private struct PanelOpenTracker: ViewModifier {
  let isOpen: Bool
  @Binding var wasClosed: Bool

  func body(content: Content) -> some View {
    content
      .onAppear { if !isOpen { wasClosed = true } }
      .onChange(of: isOpen) { _, open in if !open { wasClosed = true } }
  }
}

extension View {
  /// Apply to the host of a detail panel; pass `wasClosed` to the panel's
  /// `wbPanelEntrance(animates:)`. `isOpen` follows the selection, not data.
  func wbTracksPanelOpen(isOpen: Bool, wasClosed: Binding<Bool>) -> some View {
    modifier(PanelOpenTracker(isOpen: isOpen, wasClosed: wasClosed))
  }

  /// Fades and slides the panel's contents in when the panel appears. Apply
  /// it to the panel's contents, never to the container whose width changes.
  /// - Parameters:
  ///   - animates: Whether this appearance animates. Read, do not consume, a
  ///     `PanelEntranceGate` here.
  ///   - onAppearConsume: Consumes the gate when the panel appears.
  func wbPanelEntrance(animates: Bool = true, onAppearConsume: @escaping () -> Bool = { true }) -> some View {
    modifier(PanelEntranceModifier(animates: animates, onAppearConsume: onAppearConsume))
  }
}

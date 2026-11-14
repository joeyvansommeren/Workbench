//
//  ThemeCrossfade.swift
//  AgentHub
//
//  One window crossfade when the user switches Standard | Warm or light |
//  dark in the title row (motion plan item 13). Without it, a light ↔ dark
//  switch is a full-window brightness cut, and SwiftUI and the terminal
//  repaint at different moments, which looks broken.
//
//  How: snapshot the content view, put the image on a plain `CALayer` above
//  everything, apply the theme, fade the layer out, remove it. A sublayer
//  joins no view hierarchy, no constraints and no SwiftUI layout, so it cannot
//  feed the layout loop (CLAUDE.md "Layout-Loop Crash"). It takes no events.
//
//  Reduce Motion: the fade stays. It is opacity only and eases a brightness
//  jump. The one deliberate exception to `wbAnimation` → nil.
//
//  Kill switch: if the snapshot takes more than a frame on a 5K window
//  (Instruments), make `perform` call `change()` alone.
//

import AppKit
import QuartzCore

@MainActor
enum ThemeCrossfade {
  /// Layer name, so a second switch during a fade replaces the first overlay.
  static let layerName = "wb.themeCrossfade"

  /// Runs `change` under a crossfade of `window`'s content. Without a window,
  /// a layer, or a snapshot, it runs `change` alone.
  static func perform(in window: NSWindow?, _ change: () -> Void) {
    guard
      let contentView = window?.contentView,
      let rootLayer = contentView.layer,
      let snapshot = snapshot(of: contentView)
    else {
      change()
      return
    }

    // A switch during a running fade: drop the old overlay; the new snapshot
    // already shows what is on screen now.
    rootLayer.sublayers?.filter { $0.name == layerName }.forEach { $0.removeFromSuperlayer() }

    let overlay = makeOverlay(image: snapshot, bounds: rootLayer.bounds, scale: window?.backingScaleFactor ?? 2)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rootLayer.addSublayer(overlay)
    CATransaction.commit()

    change()

    CATransaction.begin()
    CATransaction.setCompletionBlock { overlay.removeFromSuperlayer() }
    overlay.add(fadeAnimation(), forKey: "fade")
    // The model value is the end state; the animation runs from 1.
    CATransaction.setDisableActions(true)
    overlay.opacity = 0
    CATransaction.commit()

    // Fallback: if the window stops drawing (hidden, miniaturised), Core
    // Animation may hold the completion. The overlay must never stay.
    // A run-loop timer in common modes also fires during menu tracking.
    let cleanup = Timer(timeInterval: DesignTokens.Motion.themeCrossfadeDuration + 0.25, repeats: false) { _ in
      overlay.removeFromSuperlayer()
    }
    RunLoop.main.add(cleanup, forMode: .common)
  }

  /// The fade: 1 → 0 over the token duration on the prototype's ease-out.
  static func fadeAnimation() -> CABasicAnimation {
    let points = DesignTokens.Motion.themeCrossfadeTimingControlPoints
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.duration = DesignTokens.Motion.themeCrossfadeDuration
    fade.timingFunction = CAMediaTimingFunction(controlPoints: points.0, points.1, points.2, points.3)
    return fade
  }

  static func snapshot(of view: NSView) -> CGImage? {
    let bounds = view.bounds
    guard bounds.width > 0, bounds.height > 0,
      let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
    else { return nil }
    view.cacheDisplay(in: bounds, to: rep)
    return rep.cgImage
  }

  static func makeOverlay(image: CGImage, bounds: CGRect, scale: CGFloat) -> CALayer {
    let overlay = CALayer()
    overlay.name = layerName
    overlay.frame = bounds
    overlay.contents = image
    overlay.contentsGravity = .resize
    overlay.contentsScale = scale
    overlay.zPosition = 10_000
    overlay.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    return overlay
  }
}

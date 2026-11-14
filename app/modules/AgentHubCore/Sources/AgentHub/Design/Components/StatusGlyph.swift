//
//  StatusGlyph.swift
//  AgentHub
//
//  Canvas-drawn status glyph in a fixed 12 or 16 pt frame.
//  Animated glyphs use TimelineView so the Canvas redraws each frame.
//  Animation gates on AppVisibilityMonitor and respects Reduce Motion.
//

import SwiftUI

// MARK: - Phase maths (pure, testable)

/// Pure phase calculations for animated status glyphs.
/// Deterministic functions of wall-clock time — no state needed.
public enum StatusGlyphPhase {

  /// Arc rotation angle at the given date, in degrees.
  /// Linear: completes a full 360-degree cycle every 0.9 seconds.
  public static func arcDegrees(at date: Date) -> Double {
    let t = date.timeIntervalSinceReferenceDate
    let phase = t.truncatingRemainder(dividingBy: 0.9)
    return (phase / 0.9) * 360
  }

  /// One full breath (out and back), as the prototype's `status-breathe 1.6s`.
  public static let haloCycle: Double = 1.6
  /// The largest halo scale; `BreathingDotGlyph` maps it to the frame edge.
  public static let haloMaxScale: Double = 1.15

  /// Halo scale and opacity at the given date.
  /// Smoothstep ease-in-out, auto-reversing, one full cycle every
  /// `haloCycle` (0.8 s out, 0.8 s back), scale 0.75...1.15, opacity 0.35...0.12.
  public static func halo(at date: Date) -> (scale: Double, opacity: Double) {
    let t = date.timeIntervalSinceReferenceDate
    let half = haloCycle / 2
    // Triangle wave 0...1...0 over one cycle (auto-reversing)
    let phase = t.truncatingRemainder(dividingBy: haloCycle)
    let linear: Double
    if phase < half {
      linear = phase / half
    } else {
      linear = 1 - (phase - half) / half
    }
    // Ease-in-out: smoothstep
    let eased = linear * linear * (3 - 2 * linear)
    let scale = 0.75 + eased * (1.15 - 0.75)
    let opacity = 0.35 + eased * (0.12 - 0.35)
    return (scale: scale, opacity: opacity)
  }
}

// MARK: - StatusGlyph

/// A status glyph drawn as vector shapes in a fixed frame.
///
/// The glyph shape, colour and animation are driven entirely by
/// `SessionStatusPresentation`. The view owns no business logic.
public struct StatusGlyph: View {

  let presentation: SessionStatusPresentation
  let size: CGFloat

  /// - Parameters:
  ///   - presentation: The resolved status presentation.
  ///   - size: The frame size. Defaults to `DesignTokens.Size.status` (12).
  public init(
    presentation: SessionStatusPresentation,
    size: CGFloat = DesignTokens.Size.status
  ) {
    self.presentation = presentation
    self.size = size
  }

  /// Convenience: create from a raw status.
  public init(
    status: SessionStatus?,
    isPending: Bool = false,
    size: CGFloat = DesignTokens.Size.status
  ) {
    self.presentation = SessionStatusPresentation(status: status, isPending: isPending)
    self.size = size
  }

  public var body: some View {
    switch presentation.shape {
    case .breathingDot:
      BreathingDotGlyph(presentation: presentation, size: size)
    case .spinningArc:
      SpinningArcGlyph(presentation: presentation, size: size)
    case .filledCheck:
      FilledCheckGlyph(presentation: presentation, size: size)
    case .filledBang:
      FilledBangGlyph(presentation: presentation, size: size)
    case .ring:
      RingGlyph(presentation: presentation, size: size)
    }
  }
}

// MARK: - Breathing dot (thinking / starting)

private struct BreathingDotGlyph: View {
  let presentation: SessionStatusPresentation
  let size: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appVisibility) private var appVisibility

  private var shouldAnimate: Bool {
    StatusPulsePolicy.shouldPulse(
      isActiveStatus: true,
      isAppVisible: appVisibility?.isVisible ?? true,
      reduceMotion: reduceMotion
    )
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: nil, paused: !shouldAnimate)) { timeline in
      Canvas { context, canvasSize in
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let dotRadius = canvasSize.width * 0.25
        let halfWidth = canvasSize.width / 2

        // Halo
        if shouldAnimate {
          let haloPhase = StatusGlyphPhase.halo(at: timeline.date)
          // Map the scale range into the fixed frame: the peak (1.15) touches
          // the edge. No clamp, so the breath has no flat plateau at the top.
          let haloRadius = halfWidth * (haloPhase.scale / StatusGlyphPhase.haloMaxScale)
          let haloRect = CGRect(
            x: center.x - haloRadius,
            y: center.y - haloRadius,
            width: haloRadius * 2,
            height: haloRadius * 2
          )
          context.opacity = haloPhase.opacity
          context.fill(Circle().path(in: haloRect), with: .color(presentation.fillColor))
          context.opacity = 1
        }

        // Dot
        let dotRect = CGRect(
          x: center.x - dotRadius,
          y: center.y - dotRadius,
          width: dotRadius * 2,
          height: dotRadius * 2
        )
        context.fill(Circle().path(in: dotRect), with: .color(presentation.fillColor))
      }
    }
    .frame(width: size, height: size)
    .fixedSize()
    .accessibilityLabel(Text(presentation.accessibilityLabel))
  }
}

// MARK: - Spinning arc (executing tool)

private struct SpinningArcGlyph: View {
  let presentation: SessionStatusPresentation
  let size: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appVisibility) private var appVisibility

  private var shouldAnimate: Bool {
    StatusPulsePolicy.shouldPulse(
      isActiveStatus: true,
      isAppVisible: appVisibility?.isVisible ?? true,
      reduceMotion: reduceMotion
    )
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: nil, paused: !shouldAnimate)) { timeline in
      Canvas { context, canvasSize in
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let radius = canvasSize.width / 2 - 1
        let strokeWidth = canvasSize.width * (1.75 / 12)

        let rotation = shouldAnimate ? StatusGlyphPhase.arcDegrees(at: timeline.date) : 0

        var arcPath = Path()
        arcPath.addArc(
          center: center,
          radius: radius,
          startAngle: .degrees(rotation),
          endAngle: .degrees(rotation + 210),
          clockwise: false
        )

        context.stroke(
          arcPath,
          with: .color(presentation.fillColor),
          style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
        )
      }
    }
    .frame(width: size, height: size)
    .fixedSize()
    .accessibilityLabel(Text(presentation.accessibilityLabel))
  }
}

// MARK: - Filled circle with check (your turn)

private struct FilledCheckGlyph: View {
  let presentation: SessionStatusPresentation
  let size: CGFloat

  var body: some View {
    Canvas { context, canvasSize in
      let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
      let radius = canvasSize.width / 2

      // Filled circle
      let circleRect = CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      context.fill(Circle().path(in: circleRect), with: .color(presentation.fillColor))

      // Check mark (ink)
      let scale = canvasSize.width / 12
      var check = Path()
      check.move(to: CGPoint(x: center.x - 2.2 * scale, y: center.y + 0.2 * scale))
      check.addLine(to: CGPoint(x: center.x - 0.6 * scale, y: center.y + 1.8 * scale))
      check.addLine(to: CGPoint(x: center.x + 2.4 * scale, y: center.y - 1.8 * scale))

      context.stroke(
        check,
        with: .color(presentation.glyphInkColor),
        style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round)
      )
    }
    .frame(width: size, height: size)
    .fixedSize()
    .accessibilityLabel(Text(presentation.accessibilityLabel))
  }
}

// MARK: - Filled circle with bang (approval / input)

private struct FilledBangGlyph: View {
  let presentation: SessionStatusPresentation
  let size: CGFloat

  var body: some View {
    Canvas { context, canvasSize in
      let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
      let radius = canvasSize.width / 2

      // Filled circle
      let circleRect = CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      context.fill(Circle().path(in: circleRect), with: .color(presentation.fillColor))

      // Exclamation mark (ink): line + dot
      let scale = canvasSize.width / 12
      var line = Path()
      line.move(to: CGPoint(x: center.x, y: center.y - 2.2 * scale))
      line.addLine(to: CGPoint(x: center.x, y: center.y + 0.4 * scale))

      context.stroke(
        line,
        with: .color(presentation.glyphInkColor),
        style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round)
      )

      // Dot at the bottom
      let dotRadius = 0.7 * scale
      let dotCenter = CGPoint(x: center.x, y: center.y + 2.2 * scale)
      let dotRect = CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
      )
      context.fill(Circle().path(in: dotRect), with: .color(presentation.glyphInkColor))
    }
    .frame(width: size, height: size)
    .fixedSize()
    .accessibilityLabel(Text(presentation.accessibilityLabel))
  }
}

// MARK: - Ring (idle)

private struct RingGlyph: View {
  let presentation: SessionStatusPresentation
  let size: CGFloat

  var body: some View {
    Canvas { context, canvasSize in
      let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
      let radius = canvasSize.width / 2 - 0.75
      let strokeWidth = canvasSize.width * (1.5 / 12)

      var ring = Path()
      ring.addArc(
        center: center,
        radius: radius,
        startAngle: .zero,
        endAngle: .degrees(360),
        clockwise: false
      )

      context.stroke(
        ring,
        with: .color(presentation.fillColor),
        style: StrokeStyle(lineWidth: strokeWidth)
      )
    }
    .frame(width: size, height: size)
    .fixedSize()
    .accessibilityLabel(Text(presentation.accessibilityLabel))
  }
}

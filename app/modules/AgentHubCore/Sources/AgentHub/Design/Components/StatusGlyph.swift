//
//  StatusGlyph.swift
//  AgentHub
//
//  Canvas-drawn status glyph in a fixed 12 or 16 pt frame.
//  Animations gate on AppVisibilityMonitor and respect Reduce Motion.
//

import SwiftUI

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

  @State private var animating = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Canvas { context, canvasSize in
      let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
      let dotRadius = canvasSize.width * 0.25

      // Halo
      if !reduceMotion {
        let haloScale = animating ? 1.15 : 0.75
        let haloOpacity = animating ? 0.12 : 0.35
        let haloRadius = (canvasSize.width / 2) * haloScale
        let haloRect = CGRect(
          x: center.x - haloRadius,
          y: center.y - haloRadius,
          width: haloRadius * 2,
          height: haloRadius * 2
        )
        context.opacity = haloOpacity
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
    .frame(width: size, height: size)
    .fixedSize()
    .onAppear { startAnimation() }
    .accessibilityLabel(Text(presentation.accessibilityLabel))
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
      value: animating
    )
  }

  private func startAnimation() {
    guard !reduceMotion else { return }
    animating = true
  }
}

// MARK: - Spinning arc (executing tool)

private struct SpinningArcGlyph: View {
  let presentation: SessionStatusPresentation
  let size: CGFloat

  @State private var rotation: Double = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Canvas { context, canvasSize in
      let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
      let radius = canvasSize.width / 2 - 1
      let strokeWidth = canvasSize.width * (1.75 / 12)

      var arcPath = Path()
      // ~200 degree arc (roughly 17/(17+12) of full circle from CSS dasharray)
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
    .frame(width: size, height: size)
    .fixedSize()
    .onAppear { startAnimation() }
    .accessibilityLabel(Text(presentation.accessibilityLabel))
  }

  private func startAnimation() {
    guard !reduceMotion else { return }
    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
      rotation = 360
    }
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

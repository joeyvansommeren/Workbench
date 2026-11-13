//
//  SidebarIcons.swift
//  AgentHub
//
//  The prototype's stroked 16 × 16 sidebar icons (`#i-branch`, `#i-board`, …),
//  drawn as paths. The agent marks are custom and SF Symbols has no
//  pull-request glyph, so the sidebar draws the prototype's own SVG paths.
//  The pull-request path is the shared `PullRequestGlyphShape`.
//

import SwiftUI

enum SidebarGlyph: Sendable {
  case pullRequest
  case board
  case branch
  case folderPlus
  case chevronDown
  case plus
  case agentClaude
  case agentCodex

  /// Stroke width in the 16-unit view box. The agent marks use 1.6 like the
  /// prototype; every other icon uses `.icon`'s 1.4.
  var strokeWidth: CGFloat {
    self == .agentClaude ? 1.6 : 1.4
  }
}

/// A stroked prototype icon in a fixed square frame. Colour comes from the
/// foreground style.
struct SidebarIcon: View {
  let glyph: SidebarGlyph
  var size: CGFloat = DesignTokens.Size.icon

  var body: some View {
    SidebarGlyphShape(glyph: glyph)
      .stroke(
        style: StrokeStyle(
          lineWidth: glyph.strokeWidth * size / 16,
          lineCap: .round,
          lineJoin: .round
        )
      )
      .frame(width: size, height: size)
      .fixedSize()
      .accessibilityHidden(true)
  }
}

/// The SVG paths from the prototype, in a 16 × 16 view box scaled to `rect`.
struct SidebarGlyphShape: Shape {
  let glyph: SidebarGlyph

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 16
    var path = Path()
    let p: (CGFloat, CGFloat) -> CGPoint = { x, y in
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
    let circle: (CGFloat, CGFloat, CGFloat) -> Void = { x, y, radius in
      path.addEllipse(
        in: CGRect(
          x: rect.minX + (x - radius) * scale,
          y: rect.minY + (y - radius) * scale,
          width: radius * 2 * scale,
          height: radius * 2 * scale
        ))
    }
    let line: ([(CGFloat, CGFloat)]) -> Void = { points in
      guard let first = points.first else { return }
      path.move(to: p(first.0, first.1))
      for point in points.dropFirst() {
        path.addLine(to: p(point.0, point.1))
      }
    }

    switch glyph {
    case .pullRequest:
      path.addPath(PullRequestGlyphShape().path(in: rect))

    case .board:
      path.addRoundedRect(
        in: CGRect(
          x: rect.minX + 1.75 * scale, y: rect.minY + 2.75 * scale,
          width: 12.5 * scale, height: 10.5 * scale),
        cornerSize: CGSize(width: 2.25 * scale, height: 2.25 * scale)
      )
      line([(6, 2.75), (6, 13.25)])
      line([(10, 2.75), (10, 13.25)])

    case .branch:
      circle(4.75, 3.75, 1.5)
      circle(4.75, 12.25, 1.5)
      circle(11.25, 4.75, 1.5)
      line([(4.75, 5.25), (4.75, 10.75)])
      path.move(to: p(11.25, 6.25))
      path.addCurve(to: p(4.75, 10.75), control1: p(11.25, 9.25), control2: p(4.75, 8.5))

    case .folderPlus:
      path.move(to: p(8.25, 13))
      path.addLine(to: p(3.5, 13))
      path.addArc(tangent1End: p(1.75, 13), tangent2End: p(1.75, 11.25), radius: 1.75 * scale)
      path.addLine(to: p(1.75, 4.75))
      path.addArc(tangent1End: p(1.75, 3), tangent2End: p(3.5, 3), radius: 1.75 * scale)
      path.addLine(to: p(6.1, 3))
      path.addLine(to: p(7.6, 4.5))
      path.addLine(to: p(12.5, 4.5))
      path.addArc(tangent1End: p(14.25, 4.5), tangent2End: p(14.25, 6.25), radius: 1.75 * scale)
      path.addLine(to: p(14.25, 8))
      line([(12, 10), (12, 14.5)])
      line([(9.75, 12.25), (14.25, 12.25)])

    case .chevronDown:
      line([(4.75, 6.25), (8, 9.5), (11.25, 6.25)])

    case .plus:
      line([(8, 3.25), (8, 12.75)])
      line([(3.25, 8), (12.75, 8)])

    case .agentClaude:
      line([(8, 1.6), (8, 5.9)])
      line([(8, 10.1), (8, 14.4)])
      line([(1.6, 8), (5.9, 8)])
      line([(10.1, 8), (14.4, 8)])
      line([(3.48, 3.48), (6.52, 6.52)])
      line([(9.48, 9.48), (12.52, 12.52)])
      line([(12.52, 3.48), (9.48, 6.52)])
      line([(6.52, 9.48), (3.48, 12.52)])

    case .agentCodex:
      line([(8, 1.75), (13.4, 4.9), (13.4, 11.1), (8, 14.25), (2.6, 11.1), (2.6, 4.9)])
      path.closeSubpath()
      line([(6.3, 6.2), (8.3, 8), (6.3, 9.8)])
    }
    return path
  }
}

extension SessionProviderKind {
  /// The agent mark drawn on sidebar session rows.
  var sidebarGlyph: SidebarGlyph {
    self == .codex ? .agentCodex : .agentClaude
  }
}

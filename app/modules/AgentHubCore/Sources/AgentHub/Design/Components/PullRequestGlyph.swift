//
//  PullRequestGlyph.swift
//  AgentHub
//
//  The prototype's pull-request icon (`#i-pull`): two commits on a branch and
//  an arrow into the target. SF Symbols has no pull-request glyph
//  (`arrow.triangle.pull` renders as a merge arrow), so Reviews, Sprint and
//  the sidebar draw this instead. Colour comes from the foreground style.
//

import SwiftUI

/// A stroked pull-request icon in a fixed square frame.
public struct PullRequestGlyph: View {
  let size: CGFloat

  public init(size: CGFloat = DesignTokens.Size.icon) {
    self.size = size
  }

  public var body: some View {
    PullRequestGlyphShape()
      .stroke(
        style: StrokeStyle(
          lineWidth: PullRequestGlyphShape.strokeWidth * size / 16,
          lineCap: .round,
          lineJoin: .round
        )
      )
      .frame(width: size, height: size)
      .fixedSize()
      .accessibilityHidden(true)
  }
}

/// The `#i-pull` SVG path in a 16 × 16 view box, scaled to the rect.
public struct PullRequestGlyphShape: Shape {
  /// Stroke width in the 16-unit view box (`.icon` in the prototype).
  public static let strokeWidth: CGFloat = 1.4

  public init() {}

  public func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 16
    let p: (CGFloat, CGFloat) -> CGPoint = { x, y in
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
    var path = Path()
    let commits: [(CGFloat, CGFloat)] = [(4.5, 3.75), (4.5, 12.25), (11.5, 12.25)]
    for (x, y) in commits {
      path.addEllipse(
        in: CGRect(origin: p(x - 1.5, y - 1.5), size: CGSize(width: 3 * scale, height: 3 * scale)))
    }
    path.move(to: p(4.5, 5.25))
    path.addLine(to: p(4.5, 10.75))
    path.move(to: p(11.5, 10.75))
    path.addLine(to: p(11.5, 6.5))
    path.addArc(tangent1End: p(11.5, 4.5), tangent2End: p(9.5, 4.5), radius: 2 * scale)
    path.addLine(to: p(7.25, 4.5))
    path.move(to: p(8.75, 3))
    path.addLine(to: p(7.25, 4.5))
    path.addLine(to: p(8.75, 6))
    return path
  }
}

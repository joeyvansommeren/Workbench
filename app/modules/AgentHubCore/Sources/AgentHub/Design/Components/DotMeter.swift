//
//  DotMeter.swift
//  AgentHub
//
//  A dot-matrix context meter: 20 columns x 3 rows = 60 dots.
//  Matches `.dot-meter` in the prototype.
//

import SwiftUI

/// A 20 x 3 dot-matrix meter showing a fill percentage.
///
/// - Dots up to the fill fraction are "on" (full colour).
/// - Above 80% filled, the on-dots use the attention colour.
/// - The meter is drawn as a `Canvas` for performance.
public struct DotMeter: View {
  /// The fill fraction, 0...1.
  let fraction: Double

  /// Number of columns (dots per row).
  public static let columns = 20
  /// Number of rows.
  public static let rows = 3
  /// Total dot count.
  public static let totalDots = columns * rows

  public init(fraction: Double) {
    self.fraction = max(0, min(1, fraction))
  }

  /// How many dots are filled. Round-to-nearest matches the prototype.
  public var filledCount: Int {
    Int((fraction * Double(Self.totalDots)).rounded())
  }

  /// Whether the meter uses the attention colour.
  public var isHigh: Bool {
    fraction >= 0.8
  }

  public var body: some View {
    Canvas { context, size in
      let dotSize: CGFloat = 4
      let gap: CGFloat = DesignTokens.Spacing.xxs // 2
      let cols = Self.columns
      let rows = Self.rows
      let filled = filledCount
      let high = isHigh

      for col in 0..<cols {
        for row in 0..<rows {
          let index = col * rows + row
          let x = CGFloat(col) * (dotSize + gap)
          let y = CGFloat(row) * (dotSize + gap)
          let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
          let isFilled = index < filled

          if isFilled {
            let color: Color = high ? .wbStatusAttentionFill : .wbMeterFull
            context.fill(Circle().path(in: rect), with: .color(color))
          } else {
            context.fill(Circle().path(in: rect), with: .color(.wbMeterEmpty))
          }
        }
      }
    }
    .frame(
      width: CGFloat(Self.columns) * 4 + CGFloat(Self.columns - 1) * DesignTokens.Spacing.xxs,
      height: CGFloat(Self.rows) * 4 + CGFloat(Self.rows - 1) * DesignTokens.Spacing.xxs
    )
    .fixedSize()
    .accessibilityLabel("Context")
    .accessibilityValue("\(Int((fraction * 100).rounded()))%")
  }
}

//
//  StatusGlyphPhaseTests.swift
//  AgentHubTests
//

import Testing
import Foundation
@testable import AgentHubCore

@Suite("StatusGlyphPhase")
struct StatusGlyphPhaseTests {

  // MARK: - Arc

  @Test("arc degrees cycle from 0 to 360 over 0.9 seconds")
  func arcCycle() {
    let base = Date(timeIntervalSinceReferenceDate: 0)
    let start = StatusGlyphPhase.arcDegrees(at: base)
    #expect(abs(start) < 0.01, "Arc should start near 0 at reference date")

    let mid = StatusGlyphPhase.arcDegrees(at: base.addingTimeInterval(0.45))
    #expect(abs(mid - 180) < 1, "Arc at 0.45 s should be near 180 degrees")

    // Just before the period ends
    let nearEnd = StatusGlyphPhase.arcDegrees(at: base.addingTimeInterval(0.899))
    #expect(nearEnd > 350, "Arc near 0.9 s should be close to 360")
  }

  @Test("arc degrees are always in 0..<360")
  func arcRange() {
    for i in 0..<100 {
      let date = Date(timeIntervalSinceReferenceDate: Double(i) * 0.123)
      let degrees = StatusGlyphPhase.arcDegrees(at: date)
      #expect(degrees >= 0 && degrees < 360,
        "Arc degrees \(degrees) at offset \(Double(i) * 0.123) is out of range")
    }
  }

  // MARK: - Halo

  @Test("halo scale stays in 0.75...1.15")
  func haloScaleRange() {
    for i in 0..<200 {
      let date = Date(timeIntervalSinceReferenceDate: Double(i) * 0.05)
      let (scale, _) = StatusGlyphPhase.halo(at: date)
      #expect(scale >= 0.749 && scale <= 1.151,
        "Halo scale \(scale) is out of range at offset \(Double(i) * 0.05)")
    }
  }

  @Test("halo opacity stays in 0.12...0.35")
  func haloOpacityRange() {
    for i in 0..<200 {
      let date = Date(timeIntervalSinceReferenceDate: Double(i) * 0.05)
      let (_, opacity) = StatusGlyphPhase.halo(at: date)
      #expect(opacity >= 0.119 && opacity <= 0.351,
        "Halo opacity \(opacity) is out of range at offset \(Double(i) * 0.05)")
    }
  }

  @Test("halo at period start is near minimum scale, maximum opacity")
  func haloAtStart() {
    let date = Date(timeIntervalSinceReferenceDate: 0)
    let (scale, opacity) = StatusGlyphPhase.halo(at: date)
    #expect(abs(scale - 0.75) < 0.01, "Expected scale near 0.75, got \(scale)")
    #expect(abs(opacity - 0.35) < 0.01, "Expected opacity near 0.35, got \(opacity)")
  }

  @Test("halo at half-period is near maximum scale, minimum opacity")
  func haloAtPeak() {
    let date = Date(timeIntervalSinceReferenceDate: 1.6)
    let (scale, opacity) = StatusGlyphPhase.halo(at: date)
    #expect(abs(scale - 1.15) < 0.01, "Expected scale near 1.15, got \(scale)")
    #expect(abs(opacity - 0.12) < 0.01, "Expected opacity near 0.12, got \(opacity)")
  }
}

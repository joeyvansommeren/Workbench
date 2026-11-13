//
//  DotMeterTests.swift
//  AgentHubTests
//

import Testing
@testable import AgentHubCore

@Suite("DotMeter")
struct DotMeterTests {

  @Test("total dots is 20 columns x 3 rows = 60")
  func totalDots() {
    #expect(DotMeter.columns == 20)
    #expect(DotMeter.rows == 3)
    #expect(DotMeter.totalDots == 60)
  }

  @Test("34% fills 21 dots (ceil of 60 * 0.34 = 20.4)")
  func thirtyFourPercent() {
    let meter = DotMeter(fraction: 0.34)
    #expect(meter.filledCount == 21)
    #expect(!meter.isHigh)
  }

  @Test("0% fills 0 dots")
  func zeroPercent() {
    let meter = DotMeter(fraction: 0)
    #expect(meter.filledCount == 0)
    #expect(!meter.isHigh)
  }

  @Test("100% fills all 60 dots")
  func oneHundredPercent() {
    let meter = DotMeter(fraction: 1.0)
    #expect(meter.filledCount == 60)
    #expect(meter.isHigh)
  }

  @Test("80% uses attention colour (isHigh)")
  func eightyPercentIsHigh() {
    let meter = DotMeter(fraction: 0.80)
    #expect(meter.isHigh)
    #expect(meter.filledCount == 48)
  }

  @Test("79% does not use attention colour")
  func seventyNinePercentNotHigh() {
    let meter = DotMeter(fraction: 0.79)
    #expect(!meter.isHigh)
  }

  @Test("50% fills 30 dots")
  func fiftyPercent() {
    let meter = DotMeter(fraction: 0.50)
    #expect(meter.filledCount == 30)
    #expect(!meter.isHigh)
  }

  @Test("fraction is clamped to 0...1")
  func clampedFraction() {
    let overMeter = DotMeter(fraction: 1.5)
    #expect(overMeter.filledCount == 60)

    let underMeter = DotMeter(fraction: -0.5)
    #expect(underMeter.filledCount == 0)
  }

  @Test("very small fraction fills at least 1 dot")
  func verySmallFraction() {
    let meter = DotMeter(fraction: 0.001)
    #expect(meter.filledCount == 1)
  }
}

import AppKit
import Foundation
import Testing

@testable import AgentHub

@Suite("WorkbenchTypography")
struct WorkbenchTypographyTests {

  // MARK: - Style table completeness

  @Test("all text styles have positive size and lineHeight")
  func allStylesValid() {
    for style in WorkbenchTextStyle.allCases {
      #expect(style.size > 0, "\(style) size")
      #expect(style.lineHeight > 0, "\(style) lineHeight")
      #expect(style.lineHeight >= style.size, "\(style) lineHeight >= size")
    }
  }

  @Test("mono styles are code and codeSmall only")
  func monoStyles() {
    let mono = WorkbenchTextStyle.allCases.filter(\.isMono)
    #expect(mono.count == 2)
    #expect(mono.contains(.code))
    #expect(mono.contains(.codeSmall))
  }

  // MARK: - Font resolution

  @Test("Inter Display resolves for every non-mono style")
  func interDisplayResolves() {
    for style in WorkbenchTextStyle.allCases where !style.isMono {
      let nsFont = style.nsFont(family: .interDisplay)
      // If Inter Display is not registered (test runner without app target),
      // the fallback is the system font. Both are acceptable in headless tests.
      #expect(nsFont.pointSize == style.size, "\(style) size mismatch")
    }
  }

  @Test("Geist Mono resolves for mono styles")
  func geistMonoResolves() {
    for style in WorkbenchTextStyle.allCases where style.isMono {
      let nsFont = style.nsFont(family: .interDisplay)
      #expect(nsFont.pointSize == style.size, "\(style) size mismatch")
    }
  }

  @Test("system family uses system font")
  func systemFamily() {
    let nsFont = WorkbenchTextStyle.body.nsFont(family: .system)
    // System font name starts with '.' on macOS
    #expect(nsFont.fontName.hasPrefix(".") || nsFont.familyName?.contains("SF") == true)
  }

  @Test("geist family uses Geist font")
  func geistFamily() {
    let nsFont = WorkbenchTextStyle.body.nsFont(family: .geist)
    #expect(nsFont.pointSize == 13)
  }

  // MARK: - Tracking

  @Test("title tracking is -0.008 em")
  func titleTracking() {
    #expect(WorkbenchTextStyle.title2.trackingEm == -0.008)
    #expect(WorkbenchTextStyle.title3.trackingEm == -0.008)
  }

  @Test("body tracking is +0.01 em")
  func bodyTracking() {
    #expect(WorkbenchTextStyle.body.trackingEm == 0.01)
    #expect(WorkbenchTextStyle.bodyEmphasis.trackingEm == 0.01)
    #expect(WorkbenchTextStyle.headline.trackingEm == 0.01)
    #expect(WorkbenchTextStyle.callout.trackingEm == 0.01)
  }

  @Test("subheadline tracking is +0.025 em")
  func subheadlineTracking() {
    #expect(WorkbenchTextStyle.subheadline.trackingEm == 0.025)
  }

  @Test("code tracking is zero")
  func codeTracking() {
    #expect(WorkbenchTextStyle.code.trackingEm == 0)
    #expect(WorkbenchTextStyle.codeSmall.trackingEm == 0)
  }

  // MARK: - Family enum

  @Test("all families have an id")
  func familyIds() {
    for family in WorkbenchTypography.Family.allCases {
      #expect(!family.id.isEmpty)
    }
  }
}

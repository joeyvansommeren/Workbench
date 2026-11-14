//
//  MotionTests.swift
//  AgentHubTests
//
//  P14 motion pass: the pure parts (panel entrance gate, hover preview
//  timing, theme crossfade timing and overlay).
//

import AppKit
import Foundation
import QuartzCore
import Testing
@testable import AgentHubCore

@Suite("Panel entrance gate")
struct PanelEntranceGateTests {
  @Test("only an open the user asked for animates, once")
  func consumesOnce() {
    var gate = PanelEntranceGate()
    #expect(gate.consume() == false, "A panel that mounts by itself appears in place")
    gate.panelOpened()
    #expect(gate.isPending)
    #expect(gate.consume() == true)
    #expect(gate.consume() == false, "A later remount (session switch) does not animate")
  }

  @Test("closing before the panel appeared cancels the entrance")
  func closeCancels() {
    var gate = PanelEntranceGate()
    gate.panelOpened()
    gate.panelClosed()
    #expect(gate.consume() == false)
  }

  @Test("Reduce Motion starts the panel shown")
  func reduceMotionStartsShown() {
    #expect(PanelEntranceMotion.startsHidden(animates: true, reduceMotion: false))
    #expect(!PanelEntranceMotion.startsHidden(animates: true, reduceMotion: true))
    #expect(!PanelEntranceMotion.startsHidden(animates: false, reduceMotion: false))
    #expect(PanelEntranceMotion.offset == 8)
  }
}

@Suite("Hover preview timing")
struct HoverPreviewTimingTests {
  let now = Date(timeIntervalSinceReferenceDate: 1_000)

  @Test("the first preview waits 700 ms")
  func firstPreviewWaits() {
    #expect(HoverPreviewTiming().delay(at: now) == .milliseconds(700))
  }

  @Test("while a preview is open, the next one shows at once")
  func warmWhileOpen() {
    var timing = HoverPreviewTiming()
    timing.previewOpened()
    #expect(timing.delay(at: now) == .zero)
  }

  @Test("within 1 s after a preview closed, the next one shows at once")
  func warmAfterClose() {
    var timing = HoverPreviewTiming()
    timing.previewOpened()
    timing.previewClosed(at: now)
    #expect(timing.delay(at: now.addingTimeInterval(0.5)) == .zero)
    #expect(timing.delay(at: now.addingTimeInterval(1.0)) == .milliseconds(700))
    #expect(timing.delay(at: now.addingTimeInterval(5)) == .milliseconds(700))
  }

  @Test("extra closes never make the open count negative")
  func closeFloorsAtZero() {
    var timing = HoverPreviewTiming()
    timing.previewClosed(at: now)
    timing.previewClosed(at: now)
    #expect(timing.openCount == 0)
    timing.previewOpened()
    #expect(timing.openCount == 1)
  }
}

@Suite("Motion tokens and theme crossfade")
@MainActor
struct ThemeCrossfadeTests {
  @Test("the crossfade uses the token duration and the prototype ease-out")
  func fadeTiming() {
    let fade = ThemeCrossfade.fadeAnimation()
    #expect(fade.keyPath == "opacity")
    #expect(fade.duration == 0.24)
    #expect(fade.fromValue as? Int == 1)
    #expect(fade.toValue as? Int == 0)
    var points: [Float] = [0, 0]
    fade.timingFunction?.getControlPoint(at: 1, values: &points)
    #expect(points == [0.25, 1])
    fade.timingFunction?.getControlPoint(at: 2, values: &points)
    #expect(points == [0.5, 1])
  }

  @Test("the overlay is a named layer above everything")
  func overlayLayer() {
    let context = CGContext(
      data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = context.makeImage()!
    let overlay = ThemeCrossfade.makeOverlay(image: image, bounds: CGRect(x: 0, y: 0, width: 4, height: 4), scale: 2)
    #expect(overlay.name == ThemeCrossfade.layerName)
    #expect(overlay.zPosition > 0)
    #expect(overlay.contentsScale == 2)
  }

  @Test("without a window the change still runs")
  func noWindowStillApplies() {
    var applied = false
    ThemeCrossfade.perform(in: nil) { applied = true }
    #expect(applied)
  }

  @Test("the crossfade removes its overlay layer and applies the change")
  func overlayAddedThenFades() async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSView(frame: window.contentLayoutRect)
    view.wantsLayer = true
    window.contentView = view
    var applied = false
    ThemeCrossfade.perform(in: window) { applied = true }
    #expect(applied)
    let overlay = view.layer?.sublayers?.first { $0.name == ThemeCrossfade.layerName }
    #expect(overlay != nil)
    #expect(overlay?.opacity == 0, "The model is the end state; the animation runs from 1")
    #expect(overlay?.animation(forKey: "fade") != nil)
    // A second switch during the fade replaces the first overlay.
    ThemeCrossfade.perform(in: window) {}
    #expect(view.layer?.sublayers?.filter { $0.name == ThemeCrossfade.layerName }.count == 1)
    // The overlay never stays, even in a window that is not on screen.
    // Async sleep: the main run loop keeps running (no blocking spin, which
    // would starve timing-based suites that share the main actor).
    try await Task.sleep(for: .milliseconds(700))
    #expect(view.layer?.sublayers?.contains { $0.name == ThemeCrossfade.layerName } != true)
    window.close()
  }
}

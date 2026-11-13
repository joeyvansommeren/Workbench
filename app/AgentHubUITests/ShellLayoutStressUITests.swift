//
//  ShellLayoutStressUITests.swift
//  AgentHubUITests
//
//  Layout-loop stress test for the new shell (implementation plan, section 4).
//  Local only, not run in CI. After a run, check the log for zero
//  "Update Constraints" lines:
//  /usr/bin/log show --last 30m --predicate 'process == "Workbench" AND
//    (category == "Performance" OR eventMessage CONTAINS "Update Constraints"
//    OR eventMessage CONTAINS "has continued for")'
//

import XCTest

final class ShellLayoutStressUITests: XCTestCase {
  private var appSupportDirectory: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    // A throwaway app-support directory, so the run never touches real
    // sessions, workspace state or hooks.
    appSupportDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShellLayoutStress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: appSupportDirectory)
  }

  @MainActor
  func testShellSurvivesChromeStress() throws {
    let app = XCUIApplication()
    app.launchEnvironment["AGENTHUB_APP_SUPPORT_DIR"] = appSupportDirectory.path
    app.launchArguments += ["-com.agenthub.features.appleShell", "YES"]
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 20))
    // Fail instead of passing vacuously if the legacy root launched.
    XCTAssertTrue(
      app.buttons["shell.toggleSidebar"].waitForExistence(timeout: 20),
      "The new shell did not load"
    )

    // Double-click the empty title area 10× in the system 32 pt strip, then 4×
    // lower in the custom 52 pt row (TitleBarDragArea). Each zooms or un-zooms.
    let systemStrip = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0))
      .withOffset(CGVector(dx: 0, dy: 12))
    for _ in 0..<10 {
      systemStrip.doubleClick()
    }
    let customRow = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0))
      .withOffset(CGVector(dx: 0, dy: 42))
    for _ in 0..<4 {
      customRow.doubleClick()
    }
    assertRunning(app)

    for _ in 0..<10 {
      app.typeKey("s", modifierFlags: [.control, .command])
    }
    assertRunning(app)

    for _ in 0..<10 {
      app.typeKey("0", modifierFlags: [.option, .command])
    }
    assertRunning(app)

    for index in 0..<20 {
      app.typeKey(["1", "2", "3"][index % 3], modifierFlags: .command)
    }
    assertRunning(app)

    // Drag-resize from the bottom-right corner, smaller then larger.
    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -2, dy: -2))
    corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -600, dy: -400)))
    corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 400, dy: 300)))
    assertRunning(app)
  }

  private func assertRunning(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
  }
}

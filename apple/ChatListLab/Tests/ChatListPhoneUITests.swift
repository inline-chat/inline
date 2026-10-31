import XCTest

/// Runs against the ordinary phone lab on a physical iPhone. The lab's replay
/// mode has its own deterministic geometry probe; these tests exercise UIKit's
/// real gesture, accessibility, and text-selection paths.
final class ChatListPhoneUITests: XCTestCase {
  @MainActor
  private var app: XCUIApplication!

  @MainActor
  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
    if name.contains("testInteractiveKeyboardDismissalCancels") {
      throw XCTSkip("Continuous reverse-drag touch input is unavailable to public XCTest")
    }
    app = XCUIApplication()
    if name.contains("testBottomOcclusionKeepsTheBottomVisibleMessageAtTheUsableEdge") {
      app.launchArguments = ["--bottom-occlusion-test"]
    } else if name.contains("testViewportResizeWithoutScrollTouchKeepsIntent") {
      app.launchArguments = ["--resize-test"]
    } else if name.contains("testActualKeyboardKeepsTheBottomMessageAtItsEdge")
                || name.contains("testInteractiveKeyboardDismissalCompletes") {
      app.launchArguments = ["--keyboard-test"]
    } else if name.contains("testRotationFirstFrameKeepsPreparedNativeGeometry") {
      app.launchArguments = ["--rotation-test"]
      XCUIDevice.shared.orientation = .portrait
    } else if name.contains("testStationaryPressKeepsReadingAnchorUntilNativeDrag") {
      app.launchArguments = ["--interaction-ownership-test"]
    } else if name.contains("testHostKeyboard") {
      app.launchArguments = ["--host-keyboard", "--markers"]
    } else if name.contains("testReorder") {
      app.launchArguments = ["--reorder"]
    } else if name.contains("testRecordKeyboardMotion") {
      guard let mode = ProcessInfo.processInfo.environment["CHATLIST_RECORD"] else {
        throw XCTSkip("Set TEST_RUNNER_CHATLIST_RECORD to host or sampled to record")
      }
      app.launchArguments = [mode == "host" ? "--host-keyboard" : "--keyboard-test", "--markers"]
    }
    app.launch()
    XCTAssertTrue(scroll.waitForExistence(timeout: 10), "The native message scroll view did not appear")
    XCTAssertTrue(waitForMessages(), "The initial message cells did not appear")
  }

  @MainActor
  override func tearDown() async throws {
    app?.terminate()
    app = nil
    try await super.tearDown()
  }

  @MainActor
  func testNativeSwipeAndPrependKeepTheReadingRowInPlace() throws {
    scroll.swipeDown()
    scroll.swipeDown()
    XCTAssertTrue(waitForMessages(), "Native scrolling lost every message cell")

    let row = try XCTUnwrap(centralMessage(), "No message body intersects the viewport")
    let identifier = row.identifier
    let before = try XCTUnwrap(settledFrame(of: row), "The reading row never settled")
    attachScreenshot("before prepend")

    app.buttons["lab-older"].tap()
    XCTAssertTrue(waitForStatus("prepend"), "The prepend control did not finish")
    let sameRow = app.textViews[identifier]
    XCTAssertTrue(sameRow.waitForExistence(timeout: 5), "Prepending removed the reading row")
    let after = try XCTUnwrap(settledFrame(of: sameRow), "The reading row never settled after prepend")
    XCTAssertLessThanOrEqual(
      abs(after.midY - before.midY), 1,
      "Prepending older messages moved the reading row on screen"
    )
    XCTAssertTrue(waitForMessages(), "Prepending left the native list empty")
    assertAccessibilityRowOrder()
    attachScreenshot("after prepend")
  }

  @MainActor
  func testViewportControlsKeepCellsPresentAndResizeNativeScrollView() {
    let initialWidth = scroll.frame.width
    for (button, status) in [
      ("lab-height", "height"),
      ("lab-top", "top inset"),
      ("lab-bottom", "bottom inset"),
      ("lab-both", "height + insets")
    ] {
      app.buttons[button].tap()
      XCTAssertTrue(waitForStatus(status), "\(button) did not finish")
      XCTAssertTrue(waitForMessages(), "\(button) left the list without cells")
      XCTAssertGreaterThan(scroll.frame.height, 0)
    }
    attachScreenshot("height and occlusions")

    app.buttons["lab-width"].tap()
    XCTAssertTrue(waitForStatus("width"), "Width change did not finish")
    XCTAssertTrue(waitForMessages(), "Width change left the list without cells")
    XCTAssertEqual(scroll.frame.width, initialWidth - 48, accuracy: 2,
                   "The native scroll view did not receive the new exact width")
    assertAccessibilityRowOrder()
    attachScreenshot("resized width")
  }

  @MainActor
  func testBottomOcclusionKeepsTheBottomVisibleMessageAtTheUsableEdge() throws {
    scroll.swipeDown()
    scroll.swipeDown()
    XCTAssertTrue(waitForMessages(), "Native scrollback lost every message")

    app.buttons["lab-bottom-position"].tap()
    XCTAssertTrue(waitUntil(timeout: 5) { self.status.label == "Bottom fixture · message 352" },
                  "The bottom-edge fixture did not position message 352")

    let bottomBody = try XCTUnwrap(bottomVisibleMessage(),
                                   "No message body has over 100 points visible near the bottom")
    XCTAssertEqual(bottomBody.identifier, "message-body-352",
                   "The positioned body is not the bottommost visible message")
    let identifier = bottomBody.identifier
    let before = try XCTUnwrap(settledFrame(of: bottomBody), "The scrollback message never settled")
    attachScreenshot("bottom occlusion before")

    let initialStatus = status.label
    app.buttons["lab-bottom"].tap()
    XCTAssertTrue(waitForStatus("bottom inset", differingFrom: initialStatus),
                  "Opening the bottom occlusion did not finish")
    let sameBody = app.textViews[identifier]
    XCTAssertTrue(sameBody.waitForExistence(timeout: 5), "Opening the bottom occlusion lost the message")
    let open = try XCTUnwrap(settledFrame(of: sameBody), "The message never settled above the occlusion")
    XCTAssertEqual(open.minY - before.minY, -92, accuracy: 1,
                   "The bottom visible message did not follow the usable bottom edge upward")
    attachScreenshot("bottom occlusion open")

    let openStatus = status.label
    app.buttons["lab-bottom"].tap()
    XCTAssertTrue(waitForStatus("bottom inset", differingFrom: openStatus),
                  "Closing the bottom occlusion did not finish")
    let closed = try XCTUnwrap(settledFrame(of: sameBody), "The message never settled after closing")
    XCTAssertEqual(closed.minY, before.minY, accuracy: 1,
                   "Closing the bottom occlusion did not restore the message position")
    attachScreenshot("bottom occlusion closed")

    app.buttons["lab-latest"].tap()
    let latestBody = app.textViews["message-body-359"]
    XCTAssertTrue(waitUntil(timeout: 5) {
      latestBody.exists && latestBody.frame.intersection(self.scroll.frame).height > 100
    }, "Latest did not show the last message body")
    let latestBefore = try XCTUnwrap(settledFrame(of: latestBody), "The last message never settled")
    let latestStatus = status.label
    app.buttons["lab-bottom"].tap()
    XCTAssertTrue(waitForStatus("bottom inset", differingFrom: latestStatus),
                  "Opening the bottom occlusion at Latest did not finish")
    let latestOpen = try XCTUnwrap(settledFrame(of: latestBody),
                                   "The last message never settled above the occlusion")
    XCTAssertEqual(latestOpen.minY - latestBefore.minY, -92, accuracy: 1,
                   "The last message did not follow the usable bottom edge upward")
    attachScreenshot("bottom occlusion at Latest")
  }

  @MainActor
  func testViewportResizeWithoutScrollTouchKeepsIntent() throws {
    let intent = app.staticTexts["lab-session-intent"]
    XCTAssertTrue(waitUntil(timeout: 5) { intent.label == "latest; userScrolling=false" },
                  "The resize fixture did not start at Latest")
    let initialHeight = scroll.frame.height
    let lastOriginal = app.textViews["message-body-359"]
    XCTAssertTrue(lastOriginal.waitForExistence(timeout: 5), "The last row was not materialized")

    var previousStatus = status.label
    app.buttons["lab-viewport-resize"].tap()
    XCTAssertTrue(waitForViewportResize(differingFrom: previousStatus), "The viewport did not shrink")
    XCTAssertEqual(scroll.frame.height, initialHeight - 100, accuracy: 1)
    XCTAssertEqual(intent.label, "latest; userScrolling=false",
                   "A host-driven resize was classified as a user scroll")
    XCTAssertGreaterThan(lastOriginal.frame.intersection(scroll.frame).height, 0)

    previousStatus = status.label
    app.buttons["lab-viewport-resize"].tap()
    XCTAssertTrue(waitForViewportResize(differingFrom: previousStatus), "The viewport did not grow")
    XCTAssertEqual(scroll.frame.height, initialHeight, accuracy: 1)
    XCTAssertEqual(intent.label, "latest; userScrolling=false",
                   "Restoring the host height revoked Latest")
    attachScreenshot("no-touch resize at Latest")

    app.buttons["lab-newer"].tap()
    XCTAssertTrue(waitForStatus("append"), "Appending after a host resize did not finish")
    XCTAssertTrue(app.textViews["message-body-362"].waitForExistence(timeout: 5),
                  "Latest did not follow the appended message after resize")

    scroll.swipeDown()
    XCTAssertTrue(waitUntil(timeout: 5) { intent.label == "reading; userScrolling=false" },
                  "Native scrollback did not settle in reading mode")
    let readingBody = try XCTUnwrap(centralMessage(), "No reading row remained after scrollback")
    let before = try XCTUnwrap(settledFrame(of: readingBody), "The reading row never settled")
    previousStatus = status.label
    app.buttons["lab-viewport-resize"].tap()
    XCTAssertTrue(waitForViewportResize(differingFrom: previousStatus),
                  "The reading viewport did not resize")
    XCTAssertEqual(intent.label, "reading; userScrolling=false",
                   "A host-driven resize was classified as a user scroll in history")
    let after = try XCTUnwrap(settledFrame(of: readingBody), "The reading row was lost on resize")
    XCTAssertEqual(after.minY, before.minY, accuracy: 1,
                   "A no-touch host resize moved the reading row")
    attachScreenshot("no-touch resize in history")
  }

  @MainActor
  func testActualKeyboardKeepsTheBottomMessageAtItsEdge() throws {
    scroll.swipeDown()
    XCTAssertTrue(waitForMessages(), "Native scrollback lost every message")
    app.buttons["lab-bottom-position"].tap()
    XCTAssertTrue(waitUntil(timeout: 5) { self.status.label == "Bottom fixture · message 352" },
                  "The keyboard fixture did not position message 352")
    let body = app.textViews["message-body-352"]
    XCTAssertTrue(body.waitForExistence(timeout: 5), "The bottom message body did not appear")
    let bottomBody = try XCTUnwrap(bottomVisibleMessage(), "No large body is visible at the keyboard edge")
    XCTAssertEqual(bottomBody.identifier, body.identifier,
                   "Message 352 is not the bottommost body with over 100 points visible")
    let before = try XCTUnwrap(settledFrame(of: body), "The bottom message never settled")
    let beforeDistance = scroll.frame.maxY - before.maxY
    attachScreenshot("actual keyboard before")

    let keyboardField = app.textFields["lab-keyboard-field"]
    keyboardField.tap()
    XCTAssertTrue(waitUntil(timeout: 5) {
      keyboardField.value as? String == "focused true"
    }, "Tapping the native text field did not make it first responder")
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The OS keyboard did not open")
    XCTAssertTrue(waitUntil(timeout: 8) {
      keyboard.exists && keyboard.frame.minY < self.scroll.frame.maxY - 50
    }, "The OS keyboard stayed offscreen instead of overlapping the message viewport")
    let keyboardFrame = try XCTUnwrap(settledFrame(of: keyboard), "The OS keyboard never settled")
    XCTAssertLessThan(keyboardFrame.minY, scroll.frame.maxY - 50,
                      "The OS keyboard does not overlap the message viewport")
    let systemKeyboardEdge = try XCTUnwrap(keyboardSystemEdge(),
                                           "The OS keyboard end-frame edge was not reported")
    let open = try XCTUnwrap(settledFrame(of: body), "The message never settled above the keyboard")
    XCTAssertEqual(systemKeyboardEdge - open.maxY, beforeDistance, accuracy: 2,
                   "The bottom message did not keep its distance from the actual keyboard")
    XCTAssertEqual(app.staticTexts["lab-session-intent"].label, "reading; userScrolling=false")
    XCTAssertTrue(waitUntil(timeout: 5) { self.keyboardMovingSamples() >= 4 },
                  "The keyboard fixture did not measure at least four moving frames")
    XCTAssertEqual(try XCTUnwrap(keyboardMeasurementFailures(),
                                 "No keyboard measurement failure count was reported"), 0,
                   "The keyboard fixture lost a native glyph or witness while opening")
    let openingSamples = keyboardMovingSamples()
    attachScreenshot("actual keyboard open")

    app.buttons["lab-keyboard-dismiss"].tap()
    XCTAssertTrue(waitUntil(timeout: 5) { !keyboard.exists }, "The OS keyboard did not close")
    let closed = try XCTUnwrap(settledFrame(of: body), "The message never settled after keyboard close")
    XCTAssertEqual(closed.minY, before.minY, accuracy: 2,
                   "The message did not return after closing the actual keyboard")
    XCTAssertTrue(waitUntil(timeout: 5) { self.keyboardMovingSamples() >= openingSamples + 4 },
                  "The fixture did not measure the keyboard closing motion")
    let maxDrift = try XCTUnwrap(keyboardMaximumDrift(), "No keyboard motion residual was reported")
    XCTAssertLessThanOrEqual(maxDrift, 2,
                             "The message and OS keyboard diverged during their motion")
    XCTAssertEqual(try XCTUnwrap(keyboardMeasurementFailures(),
                                 "No keyboard measurement failure count was reported"), 0,
                   "The keyboard fixture lost a native glyph or witness while closing")
    attachScreenshot("actual keyboard closed")
  }

  @MainActor
  func testInteractiveKeyboardDismissalCompletes() throws {
    scroll.swipeDown()
    app.buttons["lab-bottom-position"].tap()
    XCTAssertTrue(waitUntil(timeout: 5) { self.status.label == "Bottom fixture · message 352" },
                  "The interactive keyboard fixture did not position a bottom message")

    let field = app.textFields["lab-keyboard-field"]
    field.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { field.value as? String == "focused true" },
                  "Tapping the native field did not focus it")
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(waitUntil(timeout: 8) {
      keyboard.exists && keyboard.frame.minY < self.scroll.frame.maxY - 50
    }, "The OS keyboard did not enter the message viewport")
    let open = try XCTUnwrap(settledFrame(of: keyboard), "The opened keyboard never settled")
    let openSamples = keyboardMovingSamples()
    attachScreenshot("interactive keyboard before drag")

    let completeStartY = min(max(open.minY - 24, scroll.frame.minY + 30), scroll.frame.maxY - 60)
    let completeStart = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0))
      .withOffset(CGVector(dx: 0, dy: completeStartY - scroll.frame.minY))
    completeStart.press(
      forDuration: 0.05,
      thenDragTo: completeStart.withOffset(CGVector(dx: 0, dy: max(180, open.height * 0.75)))
    )
    XCTAssertTrue(waitUntil(timeout: 8) { !keyboard.exists },
                  "A long interactive drag did not dismiss the OS keyboard")
    XCTAssertTrue(waitUntil(timeout: 5) { field.value as? String == "focused false" },
                  "The completed dismissal left the native field focused")
    XCTAssertGreaterThan(keyboardMovingSamples(), openSamples,
                         "The long drag did not measure keyboard motion")
    XCTAssertEqual(try XCTUnwrap(keyboardMeasurementFailures()), 0,
                   "The interactive completion lost a native glyph or mismatched keyboard motion")
    XCTAssertLessThanOrEqual(try XCTUnwrap(keyboardMaximumDrift()), 2,
                             "The native glyph diverged from the keyboard during interactive completion")
    attachScreenshot("interactive keyboard completed")
  }

  @MainActor
  func testInteractiveKeyboardDismissalCancels() throws {
    throw XCTSkip(
      "Public XCTest only supports a one-way drag; physical cancellation requires a partial " +
        "downward drag reversed before lifting the same touch. Verify this manually."
    )
  }

  @MainActor
  func testRotationFirstFrameKeepsPreparedNativeGeometry() throws {
    defer { XCUIDevice.shared.orientation = .portrait }
    let originalWidth = scroll.frame.width
    scroll.swipeDown()
    XCTAssertTrue(waitUntil(timeout: 5) {
      self.app.staticTexts["lab-session-intent"].label == "reading; userScrolling=false"
    }, "Native scrollback did not establish a reading anchor before rotation")
    XCTAssertTrue(waitForMessages(), "No native message is visible before rotation")
    attachScreenshot("rotation portrait before")

    // A phone's own orientation sensor can turn it back at any moment, so only
    // the recorded evidence is required, not that landscape is still showing.
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(waitUntil(timeout: 15) {
      (self.rotationCount("lab-rotation-first-frame", stage: "layouts") ?? 0) >= 1
        && (self.rotationCount("lab-rotation-first-display", stage: "displays") ?? 0) >= 1
        && self.status.label.hasSuffix("recorded")
    }, "The first landscape layout and display samples were not recorded")
    assertRotationEvidence()
    XCTAssertTrue(waitForMessages(), "Rotation lost all native message cells")
    assertAccessibilityRowOrder()
    attachScreenshot("rotation landscape settled")

    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(waitUntil(timeout: 15) {
      abs(self.scroll.frame.width - originalWidth) <= 1
        && (self.rotationCount("lab-rotation-first-frame", stage: "layouts") ?? 0) >= 2
        && (self.rotationCount("lab-rotation-first-display", stage: "displays") ?? 0) >= 2
        && self.status.label.hasSuffix("recorded")
    }, "The first restored portrait layout and display samples were not recorded")
    assertRotationEvidence()
    XCTAssertTrue(waitForMessages(), "Restoring portrait lost all native message cells")
    assertAccessibilityRowOrder()
    attachScreenshot("rotation portrait restored")
  }

  @MainActor
  func testStationaryPressKeepsReadingAnchorUntilNativeDrag() throws {
    let publication = app.staticTexts["lab-ownership-first-publication"]
    let display = app.staticTexts["lab-ownership-first-display"]
    let intent = app.staticTexts["lab-session-intent"]
    XCTAssertTrue(waitUntil(timeout: 5) {
      publication.label == "publication 1; inset 0" && display.label == "display 1; inset 0"
        && intent.label == "reading; userScrolling=false"
    }, "The explicit reading anchor was not installed on the first snapshot and display sample")
    let body = app.textViews["message-body-352"]
    XCTAssertTrue(body.waitForExistence(timeout: 5), "The explicit reading row is not visible")
    let before = try XCTUnwrap(settledFrame(of: body), "The first reading frame did not settle")
    XCTAssertEqual(ownershipMetric("failures"), 0,
                   "The first native glyph publication/display sample failed")
    attachScreenshot("ownership explicit first frame")

    let gutter = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
      .withOffset(CGVector(dx: 8, dy: 0))
    gutter.press(forDuration: 1.1)
    XCTAssertTrue(waitUntil(timeout: 5) {
      publication.label == "publication 1; inset 1"
        && display.label == "display 1; inset 1"
        && self.ownershipMetric("press") == 1
        && self.ownershipMetric("valid") == 1
        && self.ownershipMetric("update") == 1
    }, "The no-touch inset was not published during a stationary tracked press")
    XCTAssertEqual(ownershipMetric("drag"), 0,
                   "A stationary finger began a native drag")
    XCTAssertEqual(ownershipMetric("spurious"), 0,
                   "The no-touch inset was classified as user scrolling")
    XCTAssertEqual(ownershipMetric("failures"), 0,
                   "The first inset publication/display lost native glyph compensation")
    XCTAssertLessThanOrEqual(try XCTUnwrap(ownershipMetric("drift")), 2,
                             "The first inset frame moved the retained native glyph")
    XCTAssertEqual(intent.label, "reading; userScrolling=false",
                   "The stationary press transferred scroll ownership")
    let afterInset = try XCTUnwrap(settledFrame(of: body),
                                   "The message did not settle after the stationary inset")
    XCTAssertEqual(afterInset.minY - before.minY, -80, accuracy: 1,
                   "The bottom reading message did not follow the no-touch occlusion")
    attachScreenshot("ownership stationary inset")

    scroll.swipeDown()
    XCTAssertTrue(waitUntil(timeout: 5) {
      (self.ownershipMetric("drag") ?? 0) >= 1
        && (self.ownershipMetric("delta") ?? 0) > 1
    }, "A real native drag did not take scroll ownership and move the native origin")
    XCTAssertTrue(waitUntil(timeout: 5) { intent.label == "reading; userScrolling=false" },
                  "Native drag ownership did not settle back to reading")
    XCTAssertTrue(waitForMessages(), "The native drag lost every message cell")
    attachScreenshot("ownership native drag")
  }

  @MainActor
  func testNativeScrollLatestAppendDeleteAndTextLongPressStability() throws {
    let initialIDs = visibleMessageIDs()
    scroll.swipeDown()
    XCTAssertTrue(waitForMessages(), "A native swipe left no materialized messages")
    XCTAssertNotEqual(visibleMessageIDs(), initialIDs, "The native swipe did not move through messages")
    attachScreenshot("native swipe")

    let body = try XCTUnwrap(centralMessage(), "No selectable text is visible")
    body.press(forDuration: 1.0)
    XCTAssertTrue(body.exists, "Long-pressing text removed its native cell")
    XCTAssertTrue(scroll.exists, "Long-pressing text removed the list")
    attachScreenshot("native text long press")
    scroll.tap() // Dismiss the OS text menu before using the lab controls.

    app.buttons["lab-latest"].tap()
    XCTAssertTrue(app.textViews["message-body-359"].waitForExistence(timeout: 5),
                  "Latest navigation did not reach the last original message")
    app.buttons["lab-newer"].tap()
    XCTAssertTrue(waitForStatus("append"), "Appending newer messages did not finish")
    app.buttons["lab-latest"].tap()
    XCTAssertTrue(app.textViews["message-body-362"].waitForExistence(timeout: 5),
                  "Latest navigation did not reach the newly appended messages")
    app.buttons["lab-delete"].tap()
    XCTAssertTrue(waitForStatus("delete"), "Deleting a visible message did not finish")
    XCTAssertTrue(waitForMessages(), "Deleting a message left the list empty")
    assertAccessibilityRowOrder()
    attachScreenshot("latest append and delete")
  }

  // MARK: Package keyboard tracking, reordering, far jumps

  @MainActor private var listMarker: XCUIElement { app.otherElements["lab-marker-list"] }
  @MainActor private var keyboardMarker: XCUIElement { app.otherElements["lab-marker-keyboard"] }

  /// The list's usable edge settles on the keyboard edge, both ways.
  @MainActor
  func testHostKeyboardTracksTheEdge() throws {
    let closedList = listMarker.frame.maxY
    app.buttons["lab-keyboard"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard did not open")
    XCTAssertTrue(waitUntil(timeout: 3) {
      abs(self.listMarker.frame.maxY - self.keyboardMarker.frame.maxY) <= 1
    }, "List edge \(listMarker.frame.maxY) never reached keyboard edge \(keyboardMarker.frame.maxY)")
    XCTAssertLessThan(listMarker.frame.maxY, closedList - 100, "The list did not move with the keyboard")
    app.buttons["lab-keyboard"].tap()
    XCTAssertTrue(waitUntil(timeout: 3) { abs(self.listMarker.frame.maxY - closedList) <= 1 },
                  "The list did not return when the keyboard closed")
  }

  /// A drag through the keyboard dismisses it and leaves the list edge on it.
  @MainActor
  func testHostKeyboardInteractiveDismissal() throws {
    let closedList = listMarker.frame.maxY
    app.buttons["lab-keyboard"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard did not open")
    XCTAssertTrue(waitUntil(timeout: 3) {
      abs(self.listMarker.frame.maxY - self.keyboardMarker.frame.maxY) <= 1
    }, "The list edge never reached the keyboard edge")
    let frame = scroll.frame
    let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
    let end = start.withOffset(CGVector(dx: 0, dy: UIScreen.main.bounds.height - frame.minY - 0.2 * frame.height - 2))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    XCTAssertTrue(waitUntil(timeout: 4) { !self.app.keyboards.firstMatch.exists },
                  "The drag did not dismiss the keyboard")
    XCTAssertTrue(waitUntil(timeout: 3) { abs(self.listMarker.frame.maxY - closedList) <= 1 },
                  "The list edge did not settle after dismissal")
  }

  /// Long-press, drag, drop: the row commits to a new slot and stays there.
  @MainActor
  func testReorderDragsARowToANewSlot() throws {
    let row = try XCTUnwrap(centralMessage(), "No message body intersects the viewport")
    let identifier = row.identifier
    let before = try XCTUnwrap(settledFrame(of: row), "The row never settled")
    let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -before.height * 1.6)),
                withVelocity: .slow, thenHoldForDuration: 0.5)
    XCTAssertTrue(waitUntil(timeout: 5) { self.status.label.hasPrefix("Reordered") },
                  "The drop was not reported: \(status.label)")
    let same = app.textViews[identifier]
    XCTAssertTrue(same.waitForExistence(timeout: 5), "The moved row disappeared")
    let after = try XCTUnwrap(settledFrame(of: same), "The moved row never settled")
    XCTAssertLessThan(after.minY, before.minY - before.height / 2, "The row did not stay in its new slot")
    attachScreenshot("reordered")
  }

  /// A far jump reaches the first row and returns; nothing is left behind.
  @MainActor
  func testFarJumpReachesTheFirstRow() throws {
    app.buttons["lab-jump"].tap()
    XCTAssertTrue(waitUntil(timeout: 5) { self.status.label == "Navigation finished" },
                  "The jump did not finish: \(status.label)")
    XCTAssertTrue(waitForMessages(), "The jump left no message cells")
    attachScreenshot("after far jump")
    app.buttons["lab-latest"].tap()
    XCTAssertTrue(waitForMessages(), "Returning left no message cells")
  }

  /// Fails on purpose so the result bundle keeps its screen recording. Compare
  /// the green keyboard marker and the magenta list marker frame by frame.
  @MainActor
  func testRecordKeyboardMotion() throws {
    let toggle = app.buttons["lab-keyboard"]
    let sampled = !toggle.exists
    for _ in 0 ..< 4 {
      if sampled {
        app.buttons["lab-keyboard-show"].tap()
      } else {
        toggle.tap()
      }
      Thread.sleep(forTimeInterval: 1.5)
      if sampled {
        app.buttons["lab-keyboard-dismiss"].tap()
      } else {
        toggle.tap()
      }
      Thread.sleep(forTimeInterval: 1.5)
    }
    XCTFail("Recording finished; this failure keeps the attachment")
  }

  @MainActor private var scroll: XCUIElement { app.scrollViews["lab-scroll"] }
  @MainActor private var status: XCUIElement { app.staticTexts["lab-status"] }

  @MainActor
  private func messages() -> XCUIElementQuery {
    app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "message-body-"))
  }

  @MainActor
  private func waitForMessages(timeout: TimeInterval = 5) -> Bool {
    waitUntil(timeout: timeout) { !self.visibleMessageIDs().isEmpty }
  }

  @MainActor
  private func waitForStatus(_ operation: String) -> Bool {
    waitUntil(timeout: 5) { self.status.exists && self.status.label.contains("· \(operation) ·") }
  }

  @MainActor
  private func waitForStatus(_ operation: String, differingFrom previous: String) -> Bool {
    waitUntil(timeout: 5) {
      self.status.exists && self.status.label != previous
        && self.status.label.contains("· \(operation) ·")
    }
  }

  @MainActor
  private func waitForViewportResize(differingFrom previous: String) -> Bool {
    waitUntil(timeout: 5) {
      self.status.exists && self.status.label != previous
        && self.status.label.hasPrefix("Viewport height ")
    }
  }

  @MainActor
  private func keyboardMovingSamples() -> Int {
    let label = app.staticTexts["lab-keyboard-samples"].label
    return Int(label.split(separator: " ").last ?? "") ?? 0
  }

  @MainActor
  private func keyboardMaximumDrift() -> Double? {
    let parts = app.staticTexts["lab-keyboard-max-drift"].label.split(separator: " ")
    guard parts.count == 4 else { return nil }
    return Double(parts[2])
  }

  @MainActor
  private func keyboardMeasurementFailures() -> Int? {
    let parts = app.staticTexts["lab-keyboard-failures"].label.split(separator: " ")
    guard parts.count == 2, parts[0] == "failures" else { return nil }
    return Int(parts[1])
  }

  @MainActor
  private func keyboardSystemEdge() -> CGFloat? {
    let parts = app.staticTexts["lab-keyboard-system-edge"].label.split(separator: " ")
    guard parts.count == 4, parts[0] == "system", parts[1] == "edge",
          parts[3] == "pt", let value = Double(parts[2]) else { return nil }
    return CGFloat(value)
  }

  @MainActor
  private func rotationCount(_ identifier: String, stage: String) -> Int? {
    let parts = app.staticTexts[identifier].label.split(separator: " ")
    guard parts.count == 5, parts[0] == "first", parts[1] == stage,
          parts[3] == "mismatches", parts[2].last == ";" else { return nil }
    return Int(parts[2].dropLast())
  }

  @MainActor
  private func rotationMismatches(_ identifier: String) -> Int? {
    let parts = app.staticTexts[identifier].label.split(separator: " ")
    guard parts.count == 5, parts[3] == "mismatches" else { return nil }
    return Int(parts[4])
  }

  @MainActor
  private func ownershipMetric(_ key: String) -> Double? {
    let label = key == "drift" || key == "failures"
      ? app.staticTexts["lab-ownership-max-glyph-drift"].label
      : app.staticTexts["lab-ownership-phase"].label
    let parts = label.replacingOccurrences(of: ";", with: "").split(separator: " ")
    guard let index = parts.firstIndex(of: Substring(key)), index + 1 < parts.count else { return nil }
    return Double(parts[index + 1])
  }

  @MainActor
  private func assertRotationEvidence(file: StaticString = #filePath, line: UInt = #line) {
    let layoutID = "lab-rotation-first-frame"
    let displayID = "lab-rotation-first-display"
    XCTAssertEqual(rotationCount(layoutID, stage: "layouts"), rotationCount(displayID, stage: "displays"),
                   "A rotation is missing its first layout or display sample", file: file, line: line)
    XCTAssertEqual(rotationMismatches(layoutID), 0,
                   "The first synchronous layout mixed prepared and native geometry", file: file, line: line)
    XCTAssertEqual(rotationMismatches(displayID), 0,
                   "The first display callback mixed prepared and native geometry", file: file, line: line)
    let drift = app.staticTexts["lab-rotation-max-glyph-drift"].label.split(separator: " ")
    XCTAssertEqual(drift.count, 5, "The rotation glyph residual is unavailable", file: file, line: line)
    if drift.count == 5, let value = Double(drift[3]) {
      XCTAssertLessThanOrEqual(value, 2,
                               "Rotation moved the retained native glyph", file: file, line: line)
    }
    XCTAssertEqual(app.staticTexts["lab-session-intent"].label, "reading; userScrolling=false",
                   "Rotation was classified as native input", file: file, line: line)
  }

  @MainActor
  private func visibleMessageIDs() -> [Int64] {
    let viewport = scroll.frame
    return messages().allElementsBoundByIndex.compactMap { element in
      guard element.exists, element.frame.intersects(viewport) else { return nil }
      return Int64(element.identifier.replacingOccurrences(of: "message-body-", with: ""))
    }
  }

  @MainActor
  private func centralMessage() -> XCUIElement? {
    let viewport = scroll.frame
    return messages().allElementsBoundByIndex
      .filter { $0.exists && $0.frame.intersection(viewport).height > 40 }
      .min {
        abs($0.frame.intersection(viewport).midY - viewport.midY) <
          abs($1.frame.intersection(viewport).midY - viewport.midY)
      }
  }

  @MainActor
  private func bottomVisibleMessage() -> XCUIElement? {
    let viewport = scroll.frame
    return messages().allElementsBoundByIndex
      .filter {
        $0.exists && $0.frame.minY >= viewport.minY + 100
          && $0.frame.intersection(viewport).height > 100
      }
      .max {
        $0.frame.intersection(viewport).maxY < $1.frame.intersection(viewport).maxY
      }
  }

  @MainActor
  private func assertAccessibilityRowOrder(file: StaticString = #filePath, line: UInt = #line) {
    let ids = visibleMessageIDs()
    XCTAssertEqual(ids, ids.sorted(), "Accessibility traversal is out of message order", file: file, line: line)
  }

  @MainActor
  private func settledFrame(of element: XCUIElement, timeout: TimeInterval = 4) -> CGRect? {
    let deadline = Date().addingTimeInterval(timeout)
    var previous: CGRect?
    var stableSamples = 0
    while Date() < deadline {
      guard element.exists else { return nil }
      let frame = element.frame
      if let previous,
         abs(frame.minY - previous.minY) < 0.5,
         abs(frame.height - previous.height) < 0.5 {
        stableSamples += 1
        if stableSamples >= 3 { return frame }
      } else {
        stableSamples = 0
      }
      previous = frame
      Thread.sleep(forTimeInterval: 0.15)
    }
    return nil
  }

  @MainActor
  private func waitUntil(timeout: TimeInterval, condition: @MainActor () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.15)
    } while Date() < deadline
    return condition()
  }

  @MainActor
  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

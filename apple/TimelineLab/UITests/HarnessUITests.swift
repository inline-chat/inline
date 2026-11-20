import XCTest

/// Drives the production chat screen on the timeline list: the `Inline Debug` app launched with
/// `--chatlist-harness` (in-memory fixture, no network). The runner records the screen; each step
/// also leaves a named screenshot. Extra launch arguments come from `HARNESS_ARGS`.
///
/// Coordinates are for a 375 x 667 pt screen (iPhone SE).
final class HarnessUITests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = true
  }

  func launch(_ extra: [String] = []) {
    app = XCUIApplication(bundleIdentifier: "chat.inline.InlineIOS.debug")
    let env = (ProcessInfo.processInfo.environment["HARNESS_ARGS"] ?? "").split(separator: " ").map(String.init)
    app.launchArguments = ["--chatlist-harness"] + env + extra
    // With HARNESS_ATTACH the app is already running (launched by Instruments) and is only brought forward.
    if ProcessInfo.processInfo.environment["HARNESS_ATTACH"] == "1" { app.activate() } else { app.launch() }
    _ = app.buttons["Script"].waitForExistence(timeout: 10)
    Thread.sleep(forTimeInterval: 1.5)
    // Read once: a query per gesture would delay it.
    screen = app.windows.firstMatch.frame.size
    barBottom = app.navigationBars.firstMatch.frame.maxY
    print("[UITEST] screen \(screen) bar bottom \(barBottom)")
  }

  var screen = CGSize.zero
  var barBottom: CGFloat = 0

  func shot(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
    print("[UITEST] shot \(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
  }

  /// Coordinates are written for the SE (375 x 667, bar bottom 64, composer top 595). On another phone a
  /// point keeps its place relative to the screen's width and to the band between the bar and the composer;
  /// points above the bar keep their distance from the bar's bottom, points below the composer from the
  /// screen's bottom.
  func coord(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
    let size = screen
    var point = CGPoint(x: x, y: y)
    if size.height > 0, abs(size.height - 667) > 1, size.height > size.width {
      let barBottom: CGFloat = 64, composerTop: CGFloat = 595
      // Phones with a home indicator keep 34 pt under the composer.
      let newBarBottom = self.barBottom > 0 ? self.barBottom : 106
      let newComposerTop = size.height - (size.height >= 812 ? 34 : 0) - (667 - composerTop)
      point.x = x * size.width / 375
      if y <= barBottom {
        point.y = y + (newBarBottom - barBottom)
      } else if y >= composerTop {
        point.y = newComposerTop + (y - composerTop)
      } else {
        point.y = newBarBottom + (y - barBottom) * (newComposerTop - newBarBottom) / (composerTop - barBottom)
      }
    }
    return app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
  }

  /// Press, drag at `v` pt/s, hold, lift. With no hold the finger lifts while moving: a fling.
  func drag(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, v: CGFloat, hold: Double = 0) {
    print("[UITEST] drag \(Int(x0)),\(Int(y0)) -> \(Int(x1)),\(Int(y1)) v=\(Int(v)) hold=\(hold) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
    coord(x0, y0).press(forDuration: 0.05, thenDragTo: coord(x1, y1), withVelocity: XCUIGestureVelocity(v), thenHoldForDuration: hold)
  }

  var composer: XCUIElement { app.textViews.firstMatch }
  var keyboardUp: Bool { app.keyboards.count > 0 }

  func openKeyboard() {
    if composer.waitForExistence(timeout: 5) { composer.tap() }
    Thread.sleep(forTimeInterval: 1.2)
    print("[UITEST] keyboard up=\(keyboardUp)")
  }

  func script(_ item: String) {
    app.buttons["Script"].tap()
    let button = app.buttons[item]
    if button.waitForExistence(timeout: 3) { button.tap() } else { print("[UITEST] missing menu item \(item)") }
  }

  /// Openings: let the screen settle and record it.
  func testIdle() {
    launch()
    Thread.sleep(forTimeInterval: 2)
    shot("idle")
  }

  /// Flings toward older history across several pages, a slow drag, flings back, pulls past both ends.
  func testScroll() {
    launch()
    shot("scroll-start")
    for (i, v) in [2500.0, 4000, 6000, 6000, 6000, 6000].enumerated() {
      drag(190, 180, 190, 560, v: CGFloat(v))
      Thread.sleep(forTimeInterval: 0.25)
      shot("older-\(i)-moving")
      Thread.sleep(forTimeInterval: 2.5)
      shot("older-\(i)-rest")
    }
    // A finger landing on a fling: catch, hold, release.
    drag(190, 180, 190, 560, v: 5000)
    Thread.sleep(forTimeInterval: 0.3)
    drag(190, 300, 190, 310, v: 100, hold: 0.6)
    shot("caught")
    Thread.sleep(forTimeInterval: 1)
    // Slow tracking.
    drag(190, 200, 190, 500, v: 250, hold: 0.3)
    shot("slow-drag")
    for (i, v) in [3000.0, 6000, 6000, 6000, 6000, 6000, 6000].enumerated() {
      drag(190, 480, 190, 100, v: CGFloat(v))
      Thread.sleep(forTimeInterval: 2.5)
      shot("newer-\(i)-rest")
    }
    // Pull past the newest end and let go.
    drag(190, 500, 190, 200, v: 600, hold: 0.3)
    Thread.sleep(forTimeInterval: 1.2)
    shot("pulled-newest")
  }

  /// Keyboard: open, dismiss by drag at several speeds, cancel mid-drag, hold, composer growth.
  func testKeyboard() {
    launch()
    openKeyboard()
    shot("kb-open")
    for (i, v) in [2000.0, 1000, 500].enumerated() {
      drag(190, 150, 190, 640, v: CGFloat(v))
      Thread.sleep(forTimeInterval: 1.3)
      shot("kb-after-dismiss-\(i)-up=\(keyboardUp)")
      if !keyboardUp { openKeyboard() }
    }
    for (i, y) in [400.0, 450, 500].enumerated() {
      drag(190, 150, 190, CGFloat(y), v: 500, hold: 0.5)
      Thread.sleep(forTimeInterval: 1.3)
      shot("kb-after-cancel-\(i)-up=\(keyboardUp)")
      if !keyboardUp { openKeyboard() }
    }
    // Held mid-drag, then dragged back up.
    coord(190, 150).press(forDuration: 0.05, thenDragTo: coord(190, 520), withVelocity: 400, thenHoldForDuration: 1.0)
    Thread.sleep(forTimeInterval: 1.3)
    shot("kb-after-hold-up=\(keyboardUp)")
    if !keyboardUp { openKeyboard() }
    // Composer growth and shrink.
    composer.typeText("The composer grows line by line while the list keeps the newest message right above it")
    Thread.sleep(forTimeInterval: 0.8)
    shot("kb-composer-grown")
    composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 90))
    Thread.sleep(forTimeInterval: 0.8)
    shot("kb-composer-shrunk")
    // Send from the composer.
    composer.typeText("Sent on the SE")
    Thread.sleep(forTimeInterval: 0.5)
    // The composer's send button is labelled by its arrow. `typeText` types as a hardware keyboard,
    // so the software keyboard is down while it runs.
    let send = app.buttons["Up"]
    if send.exists { send.tap() } else { print("[UITEST] no send button; buttons=\(app.buttons.allElementsBoundByIndex.map { $0.label })") }
    Thread.sleep(forTimeInterval: 1.5)
    shot("kb-sent")
    // Close by tapping the list, then reopen quickly and close again mid-animation.
    drag(190, 150, 190, 640, v: 3000)
    Thread.sleep(forTimeInterval: 0.15)
    openKeyboard()
    shot("kb-reopened")
  }

  /// Live updates with the keyboard down and up, at the bottom and scrolled up.
  func testScripts() {
    launch()
    for item in ["Receive", "Send and ack", "Edit newest", "Delete newest"] {
      script(item)
      Thread.sleep(forTimeInterval: 1.2)
      shot("script-\(item)")
    }
    openKeyboard()
    script("Receive")
    Thread.sleep(forTimeInterval: 1.2)
    shot("script-kb-Receive")
    script("Stream")
    Thread.sleep(forTimeInterval: 3)
    shot("script-kb-stream-mid")
    Thread.sleep(forTimeInterval: 5)
    shot("script-kb-stream-end")
    drag(190, 150, 190, 330, v: 400, hold: 0.3)
    Thread.sleep(forTimeInterval: 1)
    shot("script-scrolled-up")
    script("Receive")
    Thread.sleep(forTimeInterval: 1.2)
    shot("script-scrolled-up-Receive")
    script("Jump far up")
    Thread.sleep(forTimeInterval: 2)
    shot("script-jump")
  }

  /// Back-swipe with the keyboard up (needs `--timeline-harness-push`): edge and content, cancel and commit.
  func testBackSwipe() {
    launch(["--timeline-harness-push"])
    openKeyboard()
    shot("back-start")
    drag(2, 300, 110, 300, v: 300, hold: 1.0)
    Thread.sleep(forTimeInterval: 1.5)
    shot("back-after-edge-cancel-up=\(keyboardUp)")
    drag(2, 300, 300, 300, v: 400, hold: 0.3)
    Thread.sleep(forTimeInterval: 1.5)
    shot("back-after-edge-commit")
    let open = app.buttons["harnessOpenChat"]
    if open.waitForExistence(timeout: 3) { open.tap() }
    Thread.sleep(forTimeInterval: 1.5)
    openKeyboard()
    drag(120, 300, 340, 300, v: 400, hold: 0.5)
    Thread.sleep(forTimeInterval: 1.5)
    shot("back-after-content-swipe")
    if open.exists, open.isHittable { open.tap(); Thread.sleep(forTimeInterval: 1.5) }
    shot("back-end")
  }

  /// Rotation with the keyboard up and down.
  func testRotate() {
    launch()
    openKeyboard()
    shot("rot-kb-portrait")
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 2.5)
    shot("rot-kb-landscape")
    XCUIDevice.shared.orientation = .portrait
    Thread.sleep(forTimeInterval: 2.5)
    shot("rot-kb-portrait-back")
    drag(190, 150, 190, 640, v: 2000)
    Thread.sleep(forTimeInterval: 1.3)
    drag(190, 180, 190, 560, v: 800)
    Thread.sleep(forTimeInterval: 2)
    shot("rot-scrolled-portrait")
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 2.5)
    shot("rot-scrolled-landscape")
    XCUIDevice.shared.orientation = .portrait
    Thread.sleep(forTimeInterval: 2.5)
    shot("rot-scrolled-portrait-back")
  }

  /// The message menu and swipe to reply, with the keyboard down and up. Positions are for the
  /// latest opening of the 420-message fixture on the SE.
  func testMenuAndSwipe() {
    launch()
    shot("menu-start")
    // Hold the outgoing "Agreed" bubble, then close the menu by tapping outside it.
    coord(240, 448).press(forDuration: 1.2)
    Thread.sleep(forTimeInterval: 0.8)
    shot("menu-open")
    coord(187, 70).tap()
    Thread.sleep(forTimeInterval: 1.2)
    shot("menu-closed")
    // Swipe the incoming "ok" bubble from right to left.
    drag(280, 521, 150, 523, v: 700, hold: 0.1)
    Thread.sleep(forTimeInterval: 1.5)
    shot("swiped-reply-up=\(keyboardUp)")
    // With the keyboard up (the reply focused the composer), hold a bubble higher up.
    if !keyboardUp { openKeyboard() }
    coord(240, 200).press(forDuration: 1.2)
    Thread.sleep(forTimeInterval: 0.8)
    shot("menu-open-kb")
    // With the keyboard up the menu sits high and its reaction bar covers the top, so tap the dimmed
    // area to the left of the action list instead.
    coord(40, 600).tap()
    Thread.sleep(forTimeInterval: 1.2)
    shot("menu-closed-kb-up=\(keyboardUp)")
  }

  /// Sticky avatars and the continuous bubble gradient under flings, catches and page prepends.
  /// The video is the evidence: an avatar stays inside its group, a bubble's colour at a fixed
  /// screen height stays constant while bubbles pass.
  func testStickyFlings() {
    launch()
    shot("sticky-start")
    // Slow held drag across a group edge, then let go without velocity.
    drag(190, 250, 190, 450, v: 200, hold: 0.5)
    shot("sticky-held")
    Thread.sleep(forTimeInterval: 1)
    // Flings toward older history, far enough to prepend pages mid-fling.
    for (i, v) in [2000.0, 4000, 6000, 6000].enumerated() {
      drag(190, 180, 190, 560, v: CGFloat(v))
      Thread.sleep(forTimeInterval: 0.2)
      shot("sticky-older-\(i)-moving")
      Thread.sleep(forTimeInterval: 2.5)
      shot("sticky-older-\(i)-rest")
    }
    // Catch a fling with a held finger, then fling back. Upward drags start above the composer (its
    // top is at 595 on the SE, 537 with a reply bar); a touch that starts on it never reaches the list.
    drag(190, 480, 190, 100, v: 4000)
    Thread.sleep(forTimeInterval: 0.3)
    drag(190, 300, 190, 305, v: 100, hold: 0.6)
    shot("sticky-caught")
    for i in 0 ..< 4 {
      drag(190, 480, 190, 100, v: 6000)
      Thread.sleep(forTimeInterval: 2.5)
      shot("sticky-newer-\(i)-rest")
    }
  }

  /// A tap that stops a fling, with no drag after it: the floating date pill should fade as it does
  /// after a fling comes to rest by itself.
  func testDatePillCatch() {
    launch()
    drag(190, 180, 190, 560, v: 4000)
    Thread.sleep(forTimeInterval: 3)
    shot("pill-rest-after-fling")
    drag(190, 180, 190, 560, v: 4000)
    Thread.sleep(forTimeInterval: 0.3)
    shot("pill-moving")
    // A short press: touch down and up, no movement, so the list's pan never begins.
    coord(187, 380).press(forDuration: 0.05)
    Thread.sleep(forTimeInterval: 2)
    shot("pill-after-tap-catch")
    Thread.sleep(forTimeInterval: 2)
    shot("pill-after-tap-catch-4s")
  }

  /// A finger on the floating date pill while a fling runs catches the fling, as anywhere else on the
  /// list, instead of jumping to the day's first message. The pill floats at y 78 on the SE.
  func testDatePillTouchMidFling() {
    launch()
    drag(190, 180, 190, 560, v: 6000)
    coord(187, 78).press(forDuration: 0.05)
    Thread.sleep(forTimeInterval: 1.5)
    shot("pill-touch-caught")
    Thread.sleep(forTimeInterval: 1.5)
    shot("pill-touch-caught-3s")
  }

  /// The composer's reply and edit bars coming and going: the rows keep their distance from the composer's
  /// top edge, at the newest message and scrolled up, as they do for the keyboard. Keyboard down, then up.
  func testComposeBars() {
    launch()
    func cycle(_ suffix: String) {
      shot("bars-\(suffix)-start")
      script("Compose reply")
      Thread.sleep(forTimeInterval: 1)
      shot("bars-\(suffix)-reply")
      script("Compose clear")
      Thread.sleep(forTimeInterval: 1)
      shot("bars-\(suffix)-reply-cleared")
      script("Compose edit")
      Thread.sleep(forTimeInterval: 1)
      shot("bars-\(suffix)-edit")
      script("Compose clear")
      Thread.sleep(forTimeInterval: 1)
      shot("bars-\(suffix)-edit-cleared")
    }
    cycle("newest")
    drag(190, 200, 190, 420, v: 400, hold: 0.3)
    Thread.sleep(forTimeInterval: 1)
    cycle("scrolled")
    drag(190, 480, 190, 100, v: 6000)
    Thread.sleep(forTimeInterval: 2.5)
    openKeyboard()
    cycle("kb")
  }

  /// Translation on and off keeps the newest row on the bottom edge; scrolled up, the reading row.
  func testTranslation() {
    launch()
    script("Translate newest")
    Thread.sleep(forTimeInterval: 1.5)
    shot("tr-stored")
    script("Toggle translation")
    Thread.sleep(forTimeInterval: 1.5)
    shot("tr-on")
    script("Toggle translation")
    Thread.sleep(forTimeInterval: 1.5)
    shot("tr-off")
    drag(190, 200, 190, 420, v: 400, hold: 0.3)
    Thread.sleep(forTimeInterval: 1)
    shot("tr-scrolled")
    script("Toggle translation")
    Thread.sleep(forTimeInterval: 1.5)
    shot("tr-scrolled-on")
    script("Toggle translation")
    Thread.sleep(forTimeInterval: 1.5)
    shot("tr-scrolled-off")
  }

  /// Send flights: the harness's send and ack, a composer send, and a reply send that collapses the
  /// reply bar. The bubble flies from the composer and the list does not drop.
  func testSendFlight() {
    launch()
    script("Send and ack")
    Thread.sleep(forTimeInterval: 1.5)
    shot("flight-script")
    openKeyboard()
    composer.typeText("Flight check on the SE")
    Thread.sleep(forTimeInterval: 0.5)
    let send = app.buttons["Up"]
    if send.exists { send.tap() } else { print("[UITEST] no send button") }
    Thread.sleep(forTimeInterval: 0.05)
    shot("flight-composer-mid")
    Thread.sleep(forTimeInterval: 1.5)
    shot("flight-composer-end")
    // Reply by swipe to the message just sent (the keyboard covers everything below y 350 on the SE),
    // then send: the reply bar goes away with the send.
    drag(280, 250, 150, 252, v: 700, hold: 0.1)
    Thread.sleep(forTimeInterval: 1)
    shot("flight-reply-bar")
    composer.typeText("Reply flight")
    Thread.sleep(forTimeInterval: 0.5)
    print("[UITEST] send exists=\(send.exists) hittable=\(send.exists && send.isHittable)")
    if send.exists { send.tap() }
    Thread.sleep(forTimeInterval: 0.05)
    shot("flight-reply-mid")
    Thread.sleep(forTimeInterval: 1.5)
    shot("flight-reply-end")
  }

  /// The jumps the collection view handled specially: a deleted message lands on its nearest neighbour, an
  /// exact jump lands on its message and is refused once history is cleared, a message not received yet
  /// waits at the live end until it arrives; then the status notice comes and goes.
  func testJumps() {
    launch()
    script("Jump to deleted 200")
    Thread.sleep(forTimeInterval: 2)
    shot("jump-deleted-nearest")
    script("Jump exact to 100")
    Thread.sleep(forTimeInterval: 2)
    shot("jump-exact-100")
    script("Collapse history")
    Thread.sleep(forTimeInterval: 1.5)
    shot("jump-collapsed")
    script("Jump exact to 100")
    Thread.sleep(forTimeInterval: 1.5)
    shot("jump-exact-cleared-refused")
    script("Jump to next incoming")
    Thread.sleep(forTimeInterval: 1.5)
    shot("jump-awaiting")
    script("Receive")
    Thread.sleep(forTimeInterval: 1.5)
    shot("jump-arrived")
    script("Toggle status notice")
    Thread.sleep(forTimeInterval: 1.2)
    shot("notice-on")
    script("Toggle status notice")
    Thread.sleep(forTimeInterval: 1.2)
    shot("notice-off")
  }

  /// A message asked for as the chat opens lands without the latest messages showing first.
  func testFocusAtOpen() {
    launch(["--timeline-harness-focus", "150"])
    Thread.sleep(forTimeInterval: 2)
    shot("focus-open-150")
  }

  /// The chat list's preview: the latest messages, no unread line, no composer.
  func testPreview() {
    launch(["--timeline-harness-preview", "--timeline-harness-open", "unread"])
    Thread.sleep(forTimeInterval: 2)
    shot("preview")
  }

  /// Long sender groups: the avatar stays at the bottom of the group's visible part while its last row is
  /// far below the screen, held and flung.
  func testDenseGroups() {
    launch(["--timeline-harness-dense"])
    for i in 0 ..< 4 {
      drag(190, 200, 190, 420, v: 400, hold: 0.3)
      Thread.sleep(forTimeInterval: 0.8)
      shot("dense-held-\(i)")
    }
    for i in 0 ..< 3 {
      drag(190, 180, 190, 560, v: 3000)
      Thread.sleep(forTimeInterval: 2.5)
      shot("dense-flung-\(i)")
    }
  }

  /// A tap on a moving list only stops it: the media under the finger does not open.
  func testFlingTap() {
    launch()
    drag(190, 180, 190, 560, v: 3000)
    coord(120, 330).press(forDuration: 0.05)
    Thread.sleep(forTimeInterval: 1.5)
    shot("fling-tap-stopped")
    XCTAssertTrue(app.buttons["Script"].exists, "a tap that stopped the fling opened something")
  }
  /// UIKit's accessibility audit of the chat screen at rest, scrolled into history and with the keyboard up.
  /// Issues are printed, not failed, so the two lists can be compared (`--timeline-harness-collection`).
  nonisolated(unsafe) static var auditIssues: [String] = []

  func testAccessibilityAudit() throws {
    launch()
    func audit(_ name: String) {
      Self.auditIssues = []
      try? app.performAccessibilityAudit { issue in
        let element = issue.element
        let what = element.map { "\($0.elementType.rawValue) id='\($0.identifier)' label='\($0.label.prefix(40))'" } ?? "nil"
        HarnessUITests.auditIssues.append("\(issue.auditType.rawValue) \(issue.compactDescription) | \(what)")
        return true
      }
      let issues = Self.auditIssues
      print("[UITEST] audit \(name) issues=\(issues.count)")
      for issue in issues { print("[UITEST] audit \(name): \(issue)") }
      shot("audit-\(name)")
    }
    audit("rest")
    drag(190, 200, 190, 520, v: 600, hold: 0.3)
    Thread.sleep(forTimeInterval: 1)
    audit("history")
    openKeyboard()
    audit("keyboard")
  }

  /// Opens and leaves the pushed chat several times, scrolling and opening a menu each time, then waits so
  /// `leaks` can be run on the app (the runner prints `[UITEST] leak-check ready`).
  func testOpenCloseCycles() {
    launch(["--timeline-harness-push"])
    for i in 0 ..< 6 {
      drag(190, 200, 190, 520, v: 2500)
      Thread.sleep(forTimeInterval: 1.2)
      coord(260, 400).press(forDuration: 0.6)
      Thread.sleep(forTimeInterval: 0.8)
      coord(30, 120).tap()
      Thread.sleep(forTimeInterval: 0.6)
      app.navigationBars.buttons.firstMatch.tap()
      Thread.sleep(forTimeInterval: 1)
      let open = app.buttons["harnessOpenChat"]
      if open.waitForExistence(timeout: 3) { open.tap() } else { print("[UITEST] no open button at cycle \(i)") }
      Thread.sleep(forTimeInterval: 1.5)
    }
    app.navigationBars.buttons.firstMatch.tap()
    Thread.sleep(forTimeInterval: 2)
    shot("cycles-closed")
    print("[UITEST] leak-check ready")
    Thread.sleep(forTimeInterval: 45)
  }
  /// Prints the screen's accessibility tree at rest, to compare the two lists' elements.
  func testAccessibilityTree() {
    launch()
    for line in app.debugDescription.split(separator: "\n") { print("[UITEST] tree \(line)") }
  }
  /// Pages up through history leaving a screenshot of each screen, for appearance and text size checks
  /// (set with `simctl ui`).
  func testHistoryShots() {
    launch()
    shot("history-0")
    for i in 1 ... 8 {
      drag(190, 180, 190, 560, v: 500, hold: 0.4)
      Thread.sleep(forTimeInterval: 0.8)
      shot("history-\(i)")
    }
  }
  /// Agent blocks: a code block and a table scroll sideways under a horizontal drag without moving the list
  /// or starting a reply; a closed disclosure opens and closes in place.
  func testAgentBlocks() {
    func sideways(_ element: XCUIElement, _ name: String) {
      guard element.waitForExistence(timeout: 3) else { return print("[UITEST] no \(name)") }
      Thread.sleep(forTimeInterval: 1)
      let y = element.frame.midY
      print("[UITEST] \(name) y \(y)")
      shot("\(name)-before")
      let window = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
      window.withOffset(CGVector(dx: screen.width - 60, dy: y)).press(
        forDuration: 0.05, thenDragTo: window.withOffset(CGVector(dx: 80, dy: y)), withVelocity: 600,
        thenHoldForDuration: 0.2
      )
      Thread.sleep(forTimeInterval: 1)
      print("[UITEST] \(name) y after \(element.frame.midY) menu=\(app.buttons["Copy"].exists)")
      shot("\(name)-after-drag")
    }
    launch(["--timeline-harness-focus", "369"])
    sideways(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'func apply'")).firstMatch, "code")
    launch(["--timeline-harness-focus", "287"])
    sideways(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Longest'")).firstMatch, "table")

    launch(["--timeline-harness-focus", "328"])
    Thread.sleep(forTimeInterval: 2)
    shot("disclosure-closed")
    let details = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Details'")).firstMatch
    if details.waitForExistence(timeout: 3) {
      print("[UITEST] details y \(details.frame.minY)")
      details.tap()
      Thread.sleep(forTimeInterval: 1)
      print("[UITEST] details y open \(details.frame.minY)")
      shot("disclosure-open")
      details.tap()
      Thread.sleep(forTimeInterval: 1)
      print("[UITEST] details y closed \(details.frame.minY)")
      shot("disclosure-closed-again")
    } else {
      print("[UITEST] no disclosure")
    }
  }

  /// A long chat flung far into history, then held still so `heap` can count the rows and views alive (the
  /// runner prints `[UITEST] heap-check ready`). Extra arguments set the size, e.g. `--timeline-harness-count 3000`.
  func testLongFlings() {
    launch()
    for i in 0 ..< 30 {
      drag(190, 180, 190, 580, v: 4000)
      Thread.sleep(forTimeInterval: i % 5 == 4 ? 2 : 0.7)
    }
    Thread.sleep(forTimeInterval: 2)
    shot("long-flings")
    print("[UITEST] heap-check ready")
    Thread.sleep(forTimeInterval: 40)
  }

  // MARK: - Journeys (2026-11-18)

  /// The message texts on screen between the bar and the composer, top to bottom, from one accessibility
  /// snapshot (reading each element's frame separately re-resolves it, so rows arriving meanwhile mix up).
  /// Labels drop their trailing time (", 00:15"). Prints them and returns them with their frames.
  @discardableResult
  func visibleTexts(_ name: String, matching prefix: String? = nil) -> [(String, CGRect)] {
    nonisolated(unsafe) let app = app!
    let top = barBottom - 4
    // XCUITest runs test methods on the main thread.
    let out: [(String, CGRect)] = MainActor.assumeIsolated {
      guard let root = try? app.windows.firstMatch.snapshot() else { return [] }
      let composer = app.textViews.firstMatch
      let bottom = composer.exists ? composer.frame.minY : root.frame.maxY
      var out: [(String, CGRect)] = []
      func walk(_ node: any XCUIElementSnapshot) {
        if node.elementType == .staticText {
          let frame = node.frame
          var label = node.label
          if let range = label.range(of: #", \d{1,2}:\d{2}( [AP]M)?$"#, options: .regularExpression) {
            label.removeSubrange(range)
          }
          if frame.height > 0, frame.minY > top, frame.maxY <= bottom, prefix.map(label.contains) ?? true {
            out.append((label, frame))
          }
        }
        for child in node.children { walk(child) }
      }
      walk(root)
      return out.sorted { $0.1.minY < $1.1.minY }
    }
    print("[UITEST] texts \(name): " + out.map { "\($0.0.prefix(24))@\(Int($0.1.minY))-\(Int($0.1.maxY))" }.joined(separator: " | "))
    return out
  }

  var composerTop: CGFloat { composer.exists ? composer.frame.minY : screen.height }

  var scrollButton: XCUIElement { app.buttons["Scroll to Bottom"] }

  /// Sends from the composer with the software keyboard: a burst of short messages, as fast as the user can.
  func testSendBurstKeyboardUp() {
    launch()
    openKeyboard()
    let send = app.buttons["Up"]
    for i in 1 ... 8 {
      composer.typeText("Burst \(i)")
      if send.exists { send.tap() } else { print("[UITEST] no send button at \(i)") }
    }
    Thread.sleep(forTimeInterval: 0.3)
    shot("burst-mid")
    Thread.sleep(forTimeInterval: 2.5)
    shot("burst-end")
    let texts = visibleTexts("burst-end", matching: "Burst")
    XCTAssertEqual(texts.map(\.0).suffix(4), (5 ... 8).map { "Burst \($0)" }, "burst out of order or missing")
    if let last = texts.last {
      print("[UITEST] last burst bottom \(last.1.maxY) composer top \(composerTop)")
      XCTAssertLessThanOrEqual(last.1.maxY, composerTop, "newest burst row under the composer")
      XCTAssertGreaterThan(last.1.maxY, composerTop - 60, "newest burst row not resting on the composer")
    }
    XCTAssertFalse(scrollButton.isHittable, "scroll button shown at the newest message")
  }

  /// Script sends and receives interleaved quickly at the bottom, keyboard up: every row arrives, the newest rests
  /// on the composer.
  func testScriptBurstKeyboardUp() {
    launch()
    openKeyboard()
    for _ in 0 ..< 3 {
      script("Send and ack")
      script("Receive")
    }
    Thread.sleep(forTimeInterval: 2.5)
    shot("script-burst-end")
    let texts = visibleTexts("script-burst-end")
    if let last = texts.last {
      print("[UITEST] last bottom \(last.1.maxY) composer top \(composerTop)")
      XCTAssertTrue(last.0.contains("Incoming"), "newest is not the last receive: \(last.0)")
      XCTAssertLessThanOrEqual(last.1.maxY, composerTop)
    }
  }

  /// Messages arrive every 300 ms while the user flings through history, catches and comes back with the
  /// scroll button. Run with `--timeline-harness-receive-every 300`.
  func testReceiveWhileFlinging() {
    launch()
    for i in 0 ..< 4 {
      drag(190, 180, 190, 560, v: 4000)
      Thread.sleep(forTimeInterval: 0.6)
      shot("rx-fling-\(i)-moving")
      Thread.sleep(forTimeInterval: 1.6)
    }
    drag(190, 480, 190, 100, v: 3000)
    Thread.sleep(forTimeInterval: 0.3)
    coord(190, 330).press(forDuration: 0.05)
    Thread.sleep(forTimeInterval: 0.5)
    let caught = visibleTexts("rx-caught")
    Thread.sleep(forTimeInterval: 1.5)
    let later = visibleTexts("rx-caught-later")
    // Arrivals below must not move the reading rows.
    if let a = caught.first(where: { !$0.0.contains("Incoming") }),
       let b = later.first(where: { $0.0 == a.0 })
    {
      print("[UITEST] reading row \(a.0.prefix(20)) \(a.1.minY) -> \(b.1.minY)")
      XCTAssertEqual(a.1.minY, b.1.minY, accuracy: 1, "reading row moved while messages arrived below")
    }
    shot("rx-caught")
    XCTAssertTrue(scrollButton.waitForExistence(timeout: 2) && scrollButton.isHittable, "no scroll button in history")
    scrollButton.tap()
    Thread.sleep(forTimeInterval: 2)
    shot("rx-bottom")
    let bottom = visibleTexts("rx-bottom", matching: "Incoming")
    if let last = bottom.last {
      print("[UITEST] newest after scroll button \(last.0) bottom \(last.1.maxY) composer \(composerTop)")
      XCTAssertLessThanOrEqual(last.1.maxY, composerTop)
      XCTAssertGreaterThan(last.1.maxY, composerTop - 80, "not at the newest after the scroll button")
    }
    Thread.sleep(forTimeInterval: 2)
    let bottom2 = visibleTexts("rx-bottom-follow", matching: "Incoming")
    if let last = bottom2.last { XCTAssertGreaterThan(last.1.maxY, composerTop - 80, "stopped following new messages") }
    shot("rx-bottom-follow")
  }

  /// Edit and delete the newest message while reading history: the reading rows stay where they are; the scroll
  /// button then brings the edited newest into view.
  func testEditDeleteNewestScrolledUp() {
    launch()
    script("Receive")
    Thread.sleep(forTimeInterval: 1)
    drag(190, 200, 190, 520, v: 600, hold: 0.3)
    Thread.sleep(forTimeInterval: 1)
    let before = visibleTexts("ed-before")
    shot("ed-scrolled")
    script("Edit newest")
    Thread.sleep(forTimeInterval: 0.5)
    script("Receive")
    Thread.sleep(forTimeInterval: 1.2)
    let edited = visibleTexts("ed-after-edit")
    shot("ed-after-edit")
    script("Delete newest")
    Thread.sleep(forTimeInterval: 1.2)
    let deleted = visibleTexts("ed-after-delete")
    shot("ed-after-delete")
    for (name, after) in [("edit", edited), ("delete", deleted)] {
      if let a = before.dropFirst().first, let b = after.first(where: { $0.0 == a.0 }) {
        print("[UITEST] \(name): \(a.0.prefix(20)) \(a.1.minY) -> \(b.1.minY)")
        XCTAssertEqual(a.1.minY, b.1.minY, accuracy: 1, "reading row moved after \(name) of the newest")
      } else {
        XCTFail("reading row gone after \(name)")
      }
    }
    scrollButton.tap()
    Thread.sleep(forTimeInterval: 1.5)
    shot("ed-bottom")
    let bottom = visibleTexts("ed-bottom")
    if let last = bottom.last {
      XCTAssertTrue(last.0.contains("edited"), "newest is not the edited message: \(last.0)")
      XCTAssertLessThanOrEqual(last.1.maxY, composerTop)
    }
    // Delete at the bottom: the next newest settles on the composer.
    script("Delete newest")
    Thread.sleep(forTimeInterval: 1.2)
    shot("ed-bottom-deleted")
    let after = visibleTexts("ed-bottom-deleted")
    if let last = after.last {
      XCTAssertFalse(last.0.contains("edited"))
      XCTAssertGreaterThan(last.1.maxY, composerTop - 80, "a gap opened under the newest after a delete")
    }
  }

  /// A reply swipe that is pulled back before the threshold does nothing; a full one shows the reply bar, and its
  /// close button takes it away with the rows back on the composer.
  func testReplySwipeCancel() {
    launch()
    let start = visibleTexts("swipe-start")
    let startGap = start.last.map { composerTop - $0.1.maxY } ?? 0
    // Partial swipe: left 40 pt then back to the start, released.
    coord(280, 521).press(forDuration: 0.05, thenDragTo: coord(250, 522), withVelocity: 150, thenHoldForDuration: 0.3)
    Thread.sleep(forTimeInterval: 1)
    shot("swipe-partial")
    let close = app.buttons.matching(NSPredicate(format: "label IN {'Cancel reply', 'Close', 'xmark', 'Cancel'}")).firstMatch
    print("[UITEST] reply bar after partial: \(close.exists)")
    let partial = visibleTexts("swipe-partial")
    if let a = start.last, let b = partial.first(where: { $0.0 == a.0 }) {
      XCTAssertEqual(a.1.minX, b.1.minX, accuracy: 1, "the swiped row did not return")
    }
    // Full swipe.
    drag(280, 521, 150, 523, v: 700, hold: 0.1)
    Thread.sleep(forTimeInterval: 1.2)
    shot("swipe-full")
    let replied = visibleTexts("swipe-full")
    print("[UITEST] keyboard \(keyboardUp) composer \(composerTop) buttons=\(app.buttons.allElementsBoundByIndex.map { $0.label })")
    if close.waitForExistence(timeout: 2) {
      close.tap()
      Thread.sleep(forTimeInterval: 1.2)
      shot("swipe-closed")
      let closed = visibleTexts("swipe-closed")
      if let last = closed.last {
        print("[UITEST] after close bottom \(last.1.maxY) composer \(composerTop)")
        // Rows keep their distance from the composer's top edge, keyboard down or up.
        XCTAssertEqual(composerTop - last.1.maxY, startGap, accuracy: 2, "a gap left under the newest after closing the reply bar")
        XCTAssertLessThanOrEqual(last.1.maxY, composerTop)
      }
    } else {
      XCTFail("no reply bar close button")
    }
    _ = replied
  }

  /// A reply's quote jumps to its original far above; as in Telegram, the scroll button first brings the reader
  /// back to the reply (when the jump took it off screen), then to the newest.
  func testReplyJumpAndBack() {
    // 352 replies to 347; neither is in one of the fixture's albums (341 is, in the 339-341 album).
    launch(["--timeline-harness-focus", "352"])
    Thread.sleep(forTimeInterval: 1.5)
    shot("quote-start")
    // A reply's text reads "Reply to <sender>, <quote>, <text>"; its quote sits right above the text.
    let before = visibleTexts("quote-before")
    let start = before.filter { $0.0.contains("Reply to") }
    var replyLeftScreen = false
    if let reply = start.first {
      app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: reply.1.minX + 30, dy: reply.1.minY - 12)).tap()
      Thread.sleep(forTimeInterval: 1.5)
      shot("quote-jumped")
      let jumped = visibleTexts("quote-jumped")
      XCTAssertNotEqual(jumped.map(\.1.minY), before.map(\.1.minY), "the quote tap did not move the list")
      replyLeftScreen = !jumped.contains { $0.0 == reply.0 }
      print("[UITEST] reply left the screen \(replyLeftScreen)")
    } else {
      XCTFail("no reply on screen")
    }
    XCTAssertTrue(scrollButton.waitForExistence(timeout: 2), "no scroll button after the jump")
    if replyLeftScreen, let reply = start.first {
      if scrollButton.isHittable { scrollButton.tap() }
      Thread.sleep(forTimeInterval: 1.5)
      shot("quote-returned")
      let returned = visibleTexts("quote-returned")
      XCTAssertTrue(returned.contains { $0.0 == reply.0 }, "the scroll button did not go back to the reply")
      // Back at the reply nothing flashes: the highlight is the jump's.
    }
    if scrollButton.isHittable { scrollButton.tap() }
    Thread.sleep(forTimeInterval: 1.5)
    shot("quote-back")
    let bottom = visibleTexts("quote-back")
    if let last = bottom.last { XCTAssertGreaterThan(last.1.maxY, composerTop - 80, "not back at the newest") }
    XCTAssertFalse(scrollButton.isHittable, "scroll button still shown at the newest")
  }

  /// Long-press menus on the topmost and bottommost rows with the keyboard up; each closes and gives the keyboard back.
  func testMenuEdgesKeyboardUp() {
    launch()
    openKeyboard()
    let texts = visibleTexts("menu-edges")
    let candidates = texts.filter { $0.1.minY > barBottom + 4 && $0.1.maxY < composerTop - 4 }
    for (name, target) in [("top", candidates.first), ("bottom", candidates.last)] {
      guard let target else { continue }
      print("[UITEST] hold \(name) \(target.0.prefix(20)) at \(target.1.midY)")
      app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: target.1.midX, dy: target.1.midY)).press(forDuration: 1.0)
      Thread.sleep(forTimeInterval: 1)
      shot("menu-\(name)-open")
      let copy = app.buttons["Copy"]
      print("[UITEST] menu \(name) copy=\(copy.exists) frame=\(copy.exists ? copy.frame : .zero)")
      if copy.exists {
        XCTAssertTrue(app.windows.firstMatch.frame.contains(copy.frame), "menu item off screen (\(name))")
      } else {
        XCTFail("no menu at the \(name) row")
      }
      // Dismiss by tapping the dim at the far left middle.
      coord(20, 330).tap()
      Thread.sleep(forTimeInterval: 1.5)
      shot("menu-\(name)-closed-up=\(keyboardUp)")
      XCTAssertTrue(keyboardUp, "keyboard not back after the \(name) menu")
      if !keyboardUp { openKeyboard() }
    }
    let after = visibleTexts("menu-edges-after")
    if let a = texts.last, let b = after.first(where: { $0.0 == a.0 }) {
      XCTAssertEqual(a.1.minY, b.1.minY, accuracy: 1, "rows moved after the menus")
    }
  }

  /// Landscape: open the keyboard, type and send; the sent row lands above the composer. Back to portrait.
  func testLandscapeCompose() {
    launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 2)
    shot("land-start")
    openKeyboard()
    shot("land-kb")
    composer.typeText("Landscape send")
    let send = app.buttons["Up"]
    if send.exists { send.tap() }
    Thread.sleep(forTimeInterval: 1.5)
    shot("land-sent")
    let texts = visibleTexts("land-sent")
    if let last = texts.last {
      print("[UITEST] landscape last \(last.0) \(last.1) composer \(composer.frame)")
      XCTAssertEqual(last.0, "Landscape send")
      XCTAssertLessThanOrEqual(last.1.maxY, composer.frame.minY)
    }
    XCUIDevice.shared.orientation = .portrait
    Thread.sleep(forTimeInterval: 2)
    shot("land-back")
    let back = visibleTexts("land-back")
    if let last = back.last {
      XCTAssertEqual(last.0, "Landscape send")
      XCTAssertLessThanOrEqual(last.1.maxY, composer.frame.minY)
    }
  }

  /// The system menu (VoiceOver stand-in): open on a row, pick Reply; the reply bar shows.
  func testSystemMenu() {
    launch(["--timeline-harness-system-menu"])
    let texts = visibleTexts("sys-start")
    guard let target = texts.dropLast().last else { return XCTFail("no rows") }
    app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: target.1.midX, dy: target.1.midY)).press(forDuration: 1.0)
    Thread.sleep(forTimeInterval: 1.2)
    shot("sys-open")
    print("[UITEST] sys buttons \(app.buttons.allElementsBoundByIndex.map { $0.label })")
    let reply = app.buttons["Reply"]
    if reply.waitForExistence(timeout: 2) {
      reply.tap()
      Thread.sleep(forTimeInterval: 1.2)
      shot("sys-replied")
    } else {
      XCTFail("no Reply in the system menu")
    }
  }

  /// Uncached unread opening, with the fetch failing: the list ends up showing messages (not a spinner forever).
  func testUnreadOpening() {
    launch()
    Thread.sleep(forTimeInterval: 2.5)
    shot("unread-open")
    let texts = visibleTexts("unread-open")
    XCTAssertFalse(texts.isEmpty, "no rows after the opening")
    print("[UITEST] spinner \(app.activityIndicators.count)")
  }

  /// Day badges, the unread line and notices grow with the text size (set per launch, so the simulator's own
  /// setting is untouched): at the default size a day's strip keeps the collection view's 44 pt; at an
  /// accessibility size it is taller. Leaves screenshots of the unread opening and the notice at both sizes.
  func testLabelRowsTextSize() {
    /// Today's day row, a few screens above the newest message (the fixture's three days end now): paged up
    /// to, with the finger held so the floating date doesn't stand in for it.
    func dayStrip(_ name: String) -> CGFloat? {
      let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show first message from'")).firstMatch
      // At an accessibility size the rows are several times taller: up to ~20 screens.
      for _ in 0 ..< 20 where !day.exists {
        drag(190, 120, 190, 580, v: 800, hold: 0.3)
        Thread.sleep(forTimeInterval: 1.2)
      }
      guard day.exists else {
        shot("\(name)-no-day")
        print("[UITEST] \(name) no day row; buttons \(app.buttons.allElementsBoundByIndex.prefix(12).map { $0.label })")
        return nil
      }
      shot("\(name)-day")
      print("[UITEST] \(name) day \(day.frame)")
      return day.frame.height
    }
    func run(_ name: String, _ size: [String]) -> CGFloat? {
      launch(["--timeline-harness-open", "unread"] + size)
      Thread.sleep(forTimeInterval: 2)
      shot("\(name)-unread")
      let line = app.staticTexts["Unread messages"]
      print("[UITEST] \(name) unread \(line.exists ? "\(line.frame)" : "none")")
      launch(size)
      script("Toggle status notice")
      Thread.sleep(forTimeInterval: 1.5)
      // At an accessibility size the harness's own Script menu is taller than the screen and the item can be
      // out of reach: the menu stays open and is closed here (the notice is then only checked at the default).
      if app.buttons["Receive"].exists {
        print("[UITEST] \(name) notice item out of reach")
        coord(190, 30).tap()
        Thread.sleep(forTimeInterval: 1)
      }
      shot("\(name)-notice")
      return dayStrip(name)
    }
    let normal = run("default", [])
    XCTAssertNotNil(normal, "no day row at the default text size")
    if let normal { XCTAssertEqual(normal, 44, accuracy: 0.5, "a day's strip changed at the default text size") }
    let large = run("ax-large", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    XCTAssertNotNil(large, "no day row at an accessibility text size")
    if let normal, let large { XCTAssertGreaterThan(large, normal + 4, "a day's strip did not grow with the text size") }
  }

  /// The reply bar comes and goes with the keyboard up: the newest row stays on the composer's top through each
  /// animation. Run with `--timeline-harness-probe`; the probe's `newestMaxY` against `composerTop` shows the gap
  /// frame by frame (the runner prints each step's time).
  func testReplyBarFollow() {
    launch()
    openKeyboard()
    for round in 0 ..< 2 {
      print("[UITEST] reply-bar show \(round) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
      drag(280, 250, 150, 252, v: 700, hold: 0.1)
      Thread.sleep(forTimeInterval: 1.2)
      shot("reply-bar-\(round)")
      let cancel = app.buttons["Cancel reply"]
      XCTAssertTrue(cancel.waitForExistence(timeout: 2), "no reply bar")
      print("[UITEST] reply-bar hide \(round) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
      if cancel.exists { cancel.tap() }
      Thread.sleep(forTimeInterval: 1.2)
      shot("reply-bar-gone-\(round)")
    }
  }

  /// Every composer and screen change the list follows, one after another: the newest row should keep its gap to the
  /// composer's top through each. Run with `--timeline-harness-probe`; each `[UITEST] step` line names the frames
  /// after it (the probe's `wall` column).
  func testTransitionSweep() {
    func step(_ name: String) {
      print("[UITEST] step \(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
    }
    func settle() { Thread.sleep(forTimeInterval: 1.3) }
    launch()
    step("keyboard-open")
    openKeyboard()
    step("type-lines")
    composer.typeText("A long draft that wraps onto a second line, then a third one, and keeps going on to a fourth line")
    settle()
    shot("sweep-lines")
    step("delete-lines")
    composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 110))
    settle()
    step("edit-bar")
    script("Compose edit")
    settle()
    shot("sweep-edit")
    step("edit-clear")
    script("Compose clear")
    settle()
    step("photo-add")
    script("Compose photo")
    settle()
    shot("sweep-photo")
    step("photo-remove")
    script("Compose remove photo")
    settle()
    // The finger also scrolls the list here, so this stretch's drift is the scroll, not a gap.
    step("keyboard-drag-dismiss")
    drag(190, 300, 190, 650, v: 400, hold: 0.3)
    settle()
    step("back-to-newest")
    if scrollButton.exists, scrollButton.isHittable { scrollButton.tap() }
    settle()
    step("photo-add-keyboard-down")
    script("Compose photo")
    settle()
    step("photo-remove-keyboard-down")
    script("Compose remove photo")
    settle()
    step("rotate-landscape")
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 2)
    shot("sweep-landscape")
    step("rotate-portrait")
    XCUIDevice.shared.orientation = .portrait
    Thread.sleep(forTimeInterval: 2)
    step("end")
  }

  /// Puts the keyboard away with a tap on the list's empty leading margin (a drag would also scroll it).
  func tapToDismissKeyboard() {
    coord(6, 330).tap()
    Thread.sleep(forTimeInterval: 1.2)
    print("[UITEST] keyboard up after tap=\(keyboardUp)")
  }

  /// The gap between the newest row's text and the composer, to compare with the opening's.
  func newestGap(_ name: String) -> CGFloat? {
    guard let last = visibleTexts(name).last else { return nil }
    let gap = composerTop - last.1.maxY
    print("[UITEST] gap \(name) \(gap) newest \(last.0.prefix(30))")
    return gap
  }

  /// Sending from far up in history: the list goes to the newest message and the sent row rests on the composer.
  func testSendFromFarHistory() {
    launch()
    for _ in 0 ..< 4 {
      drag(190, 180, 190, 560, v: 5000)
      Thread.sleep(forTimeInterval: 2)
    }
    shot("far-history")
    openKeyboard()
    composer.typeText("Sent from far up")
    app.buttons["Up"].tap()
    Thread.sleep(forTimeInterval: 2)
    shot("far-sent")
    let texts = visibleTexts("far-sent")
    XCTAssertEqual(texts.last?.0, "Sent from far up", "the sent message is not the newest on screen")
    let sentGap = newestGap("far-sent") ?? 0
    // Keyboard down again: the same gap above the composer.
    tapToDismissKeyboard()
    shot("far-sent-kb-down")
    if let gap = newestGap("far-sent-kb-down") {
      XCTAssertEqual(gap, sentGap, accuracy: 2, "the newest row does not rest on the composer")
    }
    XCTAssertFalse(scrollButton.isHittable, "scroll button shown at the newest")
  }

  /// Messages arriving every 300 ms while the keyboard opens and closes repeatedly; the newest stays on the
  /// composer. Run with `--timeline-harness-receive-every 300`.
  func testKeyboardTogglesWhileReceiving() {
    launch()
    let openGap = newestGap("kbrx-open") ?? 0
    for i in 0 ..< 4 {
      openKeyboard()
      if let gap = newestGap("kbrx-up-\(i)") {
        XCTAssertEqual(gap, openGap, accuracy: 2, "newest off the composer with the keyboard up (\(i))")
      }
      tapToDismissKeyboard()
      if let gap = newestGap("kbrx-down-\(i)") {
        XCTAssertEqual(gap, openGap, accuracy: 2, "newest off the composer with the keyboard down (\(i))")
      }
    }
    shot("kbrx-end")
  }

  /// A far jump started while a fling runs (or at rest, with `JUMP_AT_REST`), then the scroll button: the jump
  /// wins, and the button brings the newest message back onto the composer.
  func testJumpDuringFling() {
    launch()
    let openGap = newestGap("jumpfling-open") ?? 0
    let flings = ProcessInfo.processInfo.environment["JUMP_AT_REST"] != "1"
    if flings { drag(190, 180, 190, 560, v: 5000) }
    script("Jump far up")
    Thread.sleep(forTimeInterval: 2)
    shot("jumpfling-landed")
    let landed = visibleTexts("jumpfling-landed")
    XCTAssertFalse(landed.isEmpty, "blank list after the jump")
    XCTAssertTrue(scrollButton.waitForExistence(timeout: 2) && scrollButton.isHittable, "no scroll button after the jump")
    scrollButton.tap()
    for t in [0.3, 0.6, 1.2, 2.5, 5.0] {
      Thread.sleep(forTimeInterval: t - (t == 0.3 ? 0 : [0.3, 0.6, 1.2, 2.5, 5.0][[0.3, 0.6, 1.2, 2.5, 5.0].firstIndex(of: t)! - 1]))
      shot("jumpfling-back-\(t)")
      _ = newestGap("jumpfling-back-\(t)")
    }
    XCTAssertFalse(scrollButton.isHittable, "scroll button still shown at the newest")
    if let gap = newestGap("jumpfling-back") {
      XCTAssertEqual(gap, openGap, accuracy: 2, "the newest row is not on the composer after the scroll button")
    }
  }

  /// The newest messages deleted one after another, quickly: no gap opens under the newest that remains.
  func testRapidDeletes() {
    launch()
    let openGap = newestGap("del-open") ?? 0
    for _ in 0 ..< 8 { script("Delete newest") }
    Thread.sleep(forTimeInterval: 1.5)
    shot("del-end")
    if let gap = newestGap("del-end") {
      // The newest may have a different footer (sent via), so allow its height to differ by a line.
      XCTAssertLessThan(abs(gap - openGap), 45, "a gap under the newest after deletes")
    }
    let texts = visibleTexts("del-end")
    XCTAssertGreaterThan(texts.count, 3, "rows missing after deletes")
  }

  /// VoiceOver's three-finger scrolls (stand-ins in the Script menu): pages older then newer return to the same rows.
  func testVoiceOverPaging() {
    launch()
    let start = visibleTexts("vo-start")
    for i in 0 ..< 3 {
      script("VoiceOver older")
      Thread.sleep(forTimeInterval: 0.8)
      shot("vo-older-\(i)")
    }
    let older = visibleTexts("vo-older")
    XCTAssertNotEqual(older.map(\.0), start.map(\.0), "VoiceOver older did not page")
    for _ in 0 ..< 3 {
      script("VoiceOver newer")
      Thread.sleep(forTimeInterval: 0.8)
    }
    shot("vo-back")
    let back = visibleTexts("vo-back")
    XCTAssertEqual(back.last?.0, start.last?.0, "VoiceOver newer did not return to the newest")
    script("VoiceOver focusTop")
    Thread.sleep(forTimeInterval: 0.8)
    shot("vo-focus-top")
  }
  /// Opens the pushed chat eight times through the app's read-then-push path (`--timeline-harness-push
  /// --timeline-harness-prepare`); each open logs `TIMELINE_DEBUG chat-open` with its phases.
  func testPreparedOpens() {
    launch(["--timeline-harness-push", "--timeline-harness-prepare"])
    // The harness pushes the chat at setup; start from the list.
    if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
    Thread.sleep(forTimeInterval: 1)
    let open = app.buttons["harnessOpenChat"]
    for i in 0 ..< 8 {
      guard open.waitForExistence(timeout: 4) else { print("[UITEST] no open button at \(i)"); break }
      open.tap()
      Thread.sleep(forTimeInterval: 1.5)
      if i == 0 { shot("prepared-open") }
      app.navigationBars.buttons.firstMatch.tap()
      Thread.sleep(forTimeInterval: 1.2)
    }
  }

  /// The custom menu opened and closed with the keyboard down, at the latest messages and a little way up:
  /// text rows, a row with reactions (and photos when one is on screen), each closed by a tap on the dim and
  /// the last by Copy. Stamped for video: once the bubble has landed, its row must not blink.
  func testMenuCloseKeyboardDown() { menuCloseJourney(keyboardUp: false) }

  /// The same with the composer focused. With the simulator's hardware keyboard connected no keyboard shows,
  /// and the menu has its own window as with the keyboard down.
  func testMenuCloseKeyboardUp() { menuCloseJourney(keyboardUp: true) }

  func menuCloseJourney(keyboardUp wantsKeyboard: Bool) {
    launch()
    if wantsKeyboard { openKeyboard() }
    let tag = wantsKeyboard ? "kb" : "nokb"
    menuCloseHolds(tag: "\(tag)-latest", keyboardUp: wantsKeyboard)
    // A little way up, slowly (no fling), to a row with three reactions.
    drag(200, 260, 200, 560, v: 600, hold: 0.4)
    Thread.sleep(forTimeInterval: 1.2)
    menuCloseHolds(tag: "\(tag)-history", keyboardUp: wantsKeyboard)
    shot("close-\(tag)-end")
  }

  /// A short way up into history, then the lowest row's menu opened and closed again and again (Copy, then a
  /// tap on the dim), keyboard down: the row must not blank once the bubble has landed.
  func testMenuCloseHistoryRepeat() {
    launch()
    drag(200, 260, 200, 560, v: 600, hold: 0.4)
    Thread.sleep(forTimeInterval: 1.2)
    let stamp = { (what: String) in print("[UITEST] \(what) t=\(String(format: "%.3f", Date().timeIntervalSince1970))") }
    let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
    for index in 0 ..< 8 {
      guard let target = visibleTexts("repeat-\(index)").last(where: { $0.1.maxY < composerTop - 10 }) else { break }
      stamp("hold \(index) \(target.0.prefix(20)) at \(Int(target.1.midX)),\(Int(target.1.midY))")
      origin.withOffset(CGVector(dx: target.1.midX, dy: target.1.midY)).press(forDuration: 0.9)
      Thread.sleep(forTimeInterval: 0.9)
      let copy = app.buttons["Copy"]
      if index % 2 == 0, copy.exists {
        stamp("close-copy \(index)")
        copy.tap()
      } else {
        stamp("close-tap \(index)")
        coord(target.1.midX < screen.width / 2 ? 360 : 15, 330).tap()
      }
      Thread.sleep(forTimeInterval: 1.4)
    }
  }

  func menuCloseHolds(tag: String, keyboardUp wantsKeyboard: Bool) {
    let stamp = { (what: String) in print("[UITEST] \(what) t=\(String(format: "%.3f", Date().timeIntervalSince1970))") }
    let texts = visibleTexts("close-\(tag)")
    let top = barBottom + 30, bottom = composerTop - 10
    var targets: [(String, CGPoint)] = texts
      .filter { $0.1.minY > top && $0.1.maxY < bottom }
      .map { ($0.0, CGPoint(x: $0.1.midX, y: $0.1.midY)) }
    // Photos and the bubbles over reaction pills, from one accessibility snapshot.
    nonisolated(unsafe) let app = app!
    let extra: [(String, CGPoint)] = MainActor.assumeIsolated {
      guard let root = try? app.windows.firstMatch.snapshot() else { return [] }
      var out: [(String, CGPoint)] = []
      func walk(_ node: any XCUIElementSnapshot) {
        let frame = node.frame
        if node.elementType == .image, frame.width > 80, frame.height > 80, frame.minY > top, frame.maxY < bottom {
          out.append(("photo", CGPoint(x: frame.midX, y: frame.midY)))
        }
        if node.elementType == .button, ["👍", "❤️", "😂"].contains(where: node.label.contains),
           frame.minY > top + 30, frame.maxY < bottom
        {
          // The bubble just above the pill.
          out.append(("reactions \(node.label.prefix(8))", CGPoint(x: frame.midX, y: frame.minY - 14)))
        }
        for child in node.children { walk(child) }
      }
      walk(root)
      return out
    }
    print("[UITEST] extra targets \(extra.map { "\($0.0)@\(Int($0.1.x)),\(Int($0.1.y))" })")
    // One reaction row is enough; media and reactions first, then the text rows from the top, then the newest.
    var media: [(String, CGPoint)] = []
    var sawReactions = false
    for item in extra where item.0 == "photo" || !sawReactions {
      if item.0 != "photo" { sawReactions = true }
      media.append(item)
    }
    if let newest = targets.popLast() { targets = media + Array(targets.prefix(3)) + [newest] }
    let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
    for (index, target) in targets.enumerated() {
      let point = origin.withOffset(CGVector(dx: target.1.x, dy: target.1.y))
      stamp("hold \(index) \(target.0.prefix(20)) at \(Int(target.1.x)),\(Int(target.1.y))")
      point.press(forDuration: 0.9)
      Thread.sleep(forTimeInterval: 0.9)
      let copy = app.buttons["Copy"]
      // The last (newest) row is closed with Copy; the rest with a tap on the dim.
      if index == targets.count - 1, copy.exists {
        stamp("close-copy \(index)")
        copy.tap()
      } else {
        stamp("close-tap \(index)")
        // The dim on the side away from the bubble, clear of its actions.
        coord(target.1.x < screen.width / 2 ? 360 : 15, 330).tap()
      }
      Thread.sleep(forTimeInterval: 1.4)
      stamp("closed \(index) keyboard=\(keyboardUp)")
      if wantsKeyboard, !keyboardUp { openKeyboard() }
    }
  }

  /// Reactions as the app sends them (the harness publishes each twice, a round trip apart): a double tap
  /// adds the quick reaction, another removes it, and one is picked from the menu. Stamped for video.
  func testReactions() {
    launch()
    Thread.sleep(forTimeInterval: 1)
    let stamp = { (what: String) in print("[UITEST] \(what) t=\(String(format: "%.3f", Date().timeIntervalSince1970))") }
    stamp("double-tap-add")
    coord(250, 360).doubleTap()
    Thread.sleep(forTimeInterval: 1.5)
    shot("reaction-added")
    stamp("double-tap-remove")
    coord(250, 360).doubleTap()
    Thread.sleep(forTimeInterval: 1.5)
    shot("reaction-removed")
    stamp("menu-open")
    coord(250, 360).press(forDuration: 0.6)
    Thread.sleep(forTimeInterval: 0.8)
    shot("reaction-menu")
    let emoji = app.buttons.matching(NSPredicate(format: "label IN %@", ["👍", "❤️", "😂", "🔥", "🙏", "👀", "🎉", "💯"])).firstMatch
    if emoji.exists {
      stamp("menu-pick")
      emoji.tap()
    } else {
      print("[UITEST] no emoji in the menu")
      coord(30, 120).tap()
    }
    Thread.sleep(forTimeInterval: 1.5)
    shot("reaction-picked")
    stamp("done")
  }
  /// Catching a fling: held still, held then dragged on (both ways), and a quick tap. Each step is stamped so
  /// the probe (`--timeline-harness-probe`) and the video can be cut at the touch.
  func testCatches() {
    launch()
    let stamp = { (what: String) in print("[UITEST] \(what) t=\(String(format: "%.3f", Date().timeIntervalSince1970))") }
    for i in 0 ..< 2 {
      drag(190, 180, 190, 560, v: 3000)
      Thread.sleep(forTimeInterval: 0.25)
      stamp("catch-hold-\(i)")
      coord(190, 330).press(forDuration: 0.8)
      Thread.sleep(forTimeInterval: 1)
    }
    for (i, toY) in [520.0, 160.0].enumerated() {
      drag(190, 180, 190, 560, v: 3000)
      Thread.sleep(forTimeInterval: 0.25)
      stamp("catch-drag-\(i)")
      // Down, a pause, then a slow drag on: as a finger that stops the list and keeps scrolling.
      coord(190, 330).press(forDuration: 0.15, thenDragTo: coord(190, CGFloat(toY)), withVelocity: 250, thenHoldForDuration: 0.3)
      Thread.sleep(forTimeInterval: 1.2)
    }
    for i in 0 ..< 2 {
      drag(190, 180, 190, 560, v: 3000)
      Thread.sleep(forTimeInterval: 0.25)
      stamp("catch-tap-\(i)")
      coord(300, 330).press(forDuration: 0.05)
      Thread.sleep(forTimeInterval: 1)
    }
    // Back at the newest message: a fling past it, caught by a tap while it bounces, springs back.
    script("Jump far up")
    Thread.sleep(forTimeInterval: 0.3)
    if scrollButton.waitForExistence(timeout: 2) { scrollButton.tap() }
    Thread.sleep(forTimeInterval: 1.5)
    for i in 0 ..< 2 {
      drag(190, 500, 190, 180, v: 3000)
      Thread.sleep(forTimeInterval: 0.08)
      stamp("bounce-tap-\(i)")
      coord(300, 330).press(forDuration: 0.05)
      Thread.sleep(forTimeInterval: 1.2)
    }
    stamp("done")
  }
  /// Messages arriving from the sender of the last group: the sender's avatar slides down with the group to
  /// the newest message instead of vanishing and fading in there. The first starts a group of its own (the
  /// fixture's last message was sent through an agent); the next ones join it. Stamped for video.
  func testIncomingAvatar() {
    launch()
    Thread.sleep(forTimeInterval: 1)
    for i in 0 ..< 4 {
      print("[UITEST] receive-\(i) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
      script("Receive")
      Thread.sleep(forTimeInterval: 1.5)
    }
    shot("incoming-avatar-end")
  }

  /// Rotation on any screen size (an iPad): at the newest message, scrolled up into history and with the keyboard up,
  /// each turned to landscape and back. Run with `--timeline-harness-probe`; each `[UITEST] step` line names the
  /// frames after it. Drags use fractions of the window, so no point depends on the screen.
  func testRotationSweep() {
    func step(_ name: String) {
      print("[UITEST] step \(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
    }
    func turn(_ orientation: UIDeviceOrientation, _ name: String) {
      step(name)
      XCUIDevice.shared.orientation = orientation
      Thread.sleep(forTimeInterval: 2)
      shot("rotation-\(name)")
    }
    launch()
    turn(.landscapeLeft, "landscape")
    turn(.portrait, "portrait")
    step("scroll-up")
    let window = app.windows.firstMatch
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(
      forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
      withVelocity: 600, thenHoldForDuration: 0.4
    )
    Thread.sleep(forTimeInterval: 1.3)
    turn(.landscapeLeft, "scrolled-landscape")
    turn(.portrait, "scrolled-portrait")
    step("back-to-newest")
    if scrollButton.exists, scrollButton.isHittable { scrollButton.tap() }
    Thread.sleep(forTimeInterval: 1.3)
    step("keyboard-open")
    openKeyboard()
    turn(.landscapeLeft, "keyboard-landscape")
    turn(.portrait, "keyboard-portrait")
    // Both sizes seen with the keyboard up: the composer moves with the turn to where the keyboard will be.
    turn(.landscapeLeft, "keyboard-landscape-again")
    turn(.portrait, "keyboard-portrait-again")
    step("end")
  }
}

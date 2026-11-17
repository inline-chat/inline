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
}

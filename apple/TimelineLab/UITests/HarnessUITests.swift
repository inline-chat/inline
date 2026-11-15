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
  }

  func shot(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
    print("[UITEST] shot \(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
  }

  func coord(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
    app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
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
      drag(190, 560, 190, 180, v: CGFloat(v))
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
    coord(187, 70).tap()
    Thread.sleep(forTimeInterval: 1.2)
    shot("menu-closed-kb-up=\(keyboardUp)")
  }
}

import XCTest

final class LabUITests: XCTestCase {
  var app: XCUIApplication!

  func launch(_ args: [String]) {
    app = XCUIApplication()
    app.launchArguments = args
    app.launch()
    allowRecording()
    sleep(1)
  }

  /// ReplayKit in-app capture asks once; accept it for this lab app only.
  func allowRecording() {
    let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      for alert in [sb.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
        shot("recording-prompt")
        print("[UITEST] alert: \(alert.label) buttons=\(alert.buttons.allElementsBoundByIndex.map { $0.label })")
        for label in ["Record Screen", "Allow", "Record", "OK"] where alert.buttons[label].exists {
          alert.buttons[label].tap(); sleep(1); return
        }
      }
      Thread.sleep(forTimeInterval: 0.5)
    }
    print("[UITEST] no recording prompt seen")
  }

  /// Launch with LAB_ARGS and wait LAB_WAIT seconds while the app drives itself (S1).
  func testSelfDriven() {
    launch(labArgs)
    let wait = Double(ProcessInfo.processInfo.environment["LAB_WAIT"] ?? "30") ?? 30
    Thread.sleep(forTimeInterval: wait)
    shot("run-end")
  }

  var labArgs: [String] {
    (ProcessInfo.processInfo.environment["LAB_ARGS"] ?? "-mode S2pub -driver kvo").split(separator: " ").map(String.init)
  }

  func shot(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }

  func openKeyboard() {
    let tv = app.textViews["composerText"]
    if tv.waitForExistence(timeout: 5) { tv.tap() }
    Thread.sleep(forTimeInterval: 1.2)
  }

  /// Runs a touch path on a background thread so the main thread can take screenshots during it.
  func runPath(_ p: AnyObject, name: String, shotsAt: [(Double, String)] = []) {
    let done = expectation(description: name)
    let box = UncheckedBox(p)
    let t0 = Date()
    DispatchQueue.global().async {
      let ok = Touch.run(box.value, name: name)
      if !ok { print("[UITEST] synth failed \(name)") }
      done.fulfill()
    }
    for (t, label) in shotsAt {
      let wait = t - Date().timeIntervalSince(t0)
      if wait > 0 { Thread.sleep(forTimeInterval: wait) }
      shot(label)
    }
    wait(for: [done], timeout: 30)
  }

  /// Which touch-path route honours timing?
  func testPathProbe() {
    launch(labArgs)
    let x: CGFloat = 250
    let pts = Touch.segments(from: CGPoint(x: x, y: 150), legs: [(CGPoint(x: x, y: 400), 1.0)])
    _ = Touch.run(Touch.path(pts), name: "sync120")
    sleep(2)
    let few: [(CGPoint, Double)] = [(CGPoint(x: x, y: 150), 0), (CGPoint(x: x, y: 250), 0.5), (CGPoint(x: x, y: 400), 1.0)]
    _ = Touch.run(Touch.path(few), name: "sync3")
    sleep(2)
    let e = expectation(description: "async")
    _ = Touch.runViaSynthesizer(Touch.path(pts), name: "async120") { e.fulfill() }
    wait(for: [e], timeout: 10)
    sleep(2)
    let start = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: 150))
    let end = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: 400))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(250), thenHoldForDuration: 0.2)
    sleep(2)
  }

  func coord(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
    app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
  }

  /// Public XCUITest drag: press, drag at `v` pt/s, hold, lift.
  func drag(_ y0: CGFloat, _ y1: CGFloat, v: CGFloat, hold: Double, x: CGFloat = 250) {
    coord(x, y0).press(forDuration: 0.05, thenDragTo: coord(x, y1), withVelocity: XCUIGestureVelocity(v), thenHoldForDuration: hold)
  }

  func keyboardUp() -> Bool { app.keyboards.count > 0 }

  // S2: drags over the content with the keyboard up (public XCUITest gestures; the private XCPointerEventPath
  // route does not honour its time offsets on Xcode 27.2, see S2 notes).
  func testS2() {
    launch(labArgs)
    openKeyboard()
    shot("s2-open-rest")
    // 1) dismiss: fast and medium releases (finger lifts while moving)
    for (i, v) in [1500.0, 1500, 1500, 600, 600, 600].enumerated() {
      drag(180, 650, v: v, hold: 0)
      Thread.sleep(forTimeInterval: 1.3)
      shot("s2-after-dismiss\(i)")
      if !keyboardUp() { openKeyboard() }
    }
    // 2) cancel: drag into the keyboard, hold still, lift with ~0 velocity
    for (i, y) in [430.0, 450, 470, 540, 430].enumerated() {
      drag(180, CGFloat(y), v: 600, hold: 0.4)
      Thread.sleep(forTimeInterval: 1.3)
      shot("s2-after-cancel\(i)")
      if !keyboardUp() { openKeyboard() }
    }
    // 3) held mid-drag (video frames are the held screenshots)
    drag(180, 500, v: 500, hold: 3.0)
    Thread.sleep(forTimeInterval: 1.5)
    shot("s2-after-hold")
    // 4) background with keyboard up, then foreground
    if !keyboardUp() { openKeyboard() }
    XCUIDevice.shared.press(.home)
    sleep(2)
    app.activate()
    sleep(2)
    shot("s2-after-foreground")
  }

  /// S2 private: hold a fixed keyboard offset (launch arg -privhold), tap where the 'q' key is drawn and where it was.
  func testS2PrivHold() {
    launch(labArgs)
    openKeyboard()
    sleep(1)
    shot("privhold-rest")
    let tv = app.textViews["composerText"]
    // keys are drawn 100 pt lower than their unshifted positions; tap the drawn row-1 left key, then the old position
    let win = app.windows.firstMatch
    func tapAt(_ x: CGFloat, _ y: CGFloat) {
      win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
      Thread.sleep(forTimeInterval: 0.6)
    }
    let ys: [CGFloat] = (ProcessInfo.processInfo.environment["TAP_YS"] ?? "560,460").split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
    for y in ys {
      tapAt(20, y)
      print("[UITEST] after tap y=\(y) value=\(String(describing: tv.value))")
      shot("privhold-after-tap-\(Int(y))")
    }
    XCUIDevice.shared.press(.home)
    sleep(2)
    app.activate()
    sleep(2)
    shot("privhold-after-foreground")
    print("[UITEST] final value=\(String(describing: tv.value))")
  }

  func dragXY(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, v: CGFloat, hold: Double) {
    coord(x0, y0).press(forDuration: 0.05, thenDragTo: coord(x1, y1), withVelocity: XCUIGestureVelocity(v), thenHoldForDuration: hold)
  }

  func reopenLabIfPopped() {
    let open = app.buttons["openLab"]
    if open.exists && open.isHittable { open.tap(); sleep(2) }
  }

  // S4: back-swipe with the keyboard up.
  func testS4Swipe() {
    launch(labArgs)
    sleep(2)
    shot("s4-rest")
    dragXY(2, 300, 110, 300, v: 300, hold: 1.5)          // edge, held, released early → cancel
    sleep(2); shot("s4-after-edge-cancel"); reopenLabIfPopped()
    dragXY(2, 300, 260, 300, v: 300, hold: 1.5)          // edge, held past half → commit
    sleep(2); shot("s4-after-edge-commit"); reopenLabIfPopped()
    dragXY(120, 300, 170, 300, v: 300, hold: 1.0)        // content swipe, short → cancel
    sleep(2); shot("s4-after-content-cancel"); reopenLabIfPopped()
    dragXY(120, 300, 340, 300, v: 400, hold: 1.0)        // content swipe, far → commit
    sleep(2); shot("s4-after-content-commit"); reopenLabIfPopped()
    sleep(1)
  }

  // S4: rotation with (or without, -s4kb 0) the keyboard up.
  func testS4Rotate() {
    launch(labArgs)
    sleep(2)
    shot("rot-portrait-start")
    XCUIDevice.shared.orientation = .landscapeLeft
    sleep(3)
    shot("rot-landscape")
    XCUIDevice.shared.orientation = .portrait
    sleep(3)
    shot("rot-portrait-end")
  }

  // S3: flings at three velocities (twice each), catches mid-fling, rubber band at both ends, fling into both ends.
  func testS3() {
    launch(labArgs)
    sleep(1)
    for v in [800.0, 2000, 4000] {
      for _ in 0..<2 {
        drag(200, 520, v: CGFloat(v), hold: 0)
        Thread.sleep(forTimeInterval: 4.5)
      }
    }
    // catch mid-fling: touch down right after release
    for _ in 0..<3 {
      drag(200, 520, v: 2000, hold: 0)
      coord(250, 300).tap()
      Thread.sleep(forTimeInterval: 4.5)
    }
    let top = app.buttons["toTop"], bottom = app.buttons["toBottom"]
    // rubber band at the top: pull down past the start, hold, release
    top.tap(); Thread.sleep(forTimeInterval: 0.6)
    drag(200, 450, v: 400, hold: 0.3)
    Thread.sleep(forTimeInterval: 2.0)
    // fling into the top end: move away, then fling back hard
    top.tap(); Thread.sleep(forTimeInterval: 0.6)
    drag(500, 300, v: 1500, hold: 0)
    Thread.sleep(forTimeInterval: 2.0)
    drag(200, 520, v: 4000, hold: 0)
    Thread.sleep(forTimeInterval: 4.5)
    // rubber band at the bottom (newest end): pull up past the end, hold, release
    bottom.tap(); Thread.sleep(forTimeInterval: 0.6)
    drag(500, 250, v: 400, hold: 0.3)
    Thread.sleep(forTimeInterval: 2.0)
    // fling into the bottom end from the end itself
    bottom.tap(); Thread.sleep(forTimeInterval: 0.6)
    drag(500, 200, v: 3000, hold: 0)
    Thread.sleep(forTimeInterval: 4.5)
    shot("s3-after-flings")
    openKeyboard()
    drag(180, 650, v: 1000, hold: 0)
    Thread.sleep(forTimeInterval: 1.5)
    print("[UITEST] keyboard after drag-through: \(app.keyboards.count > 0 ? "still up" : "dismissed")")
    shot("s3-after-kb-drag")
  }

  /// S3 supplement: catch mid-fling (touch-down via the private synthesizer, which does not wait for app idle)
  /// and fling into the top end. Auto-reset is off (-noreset 1); the Top/Bottom buttons position the content.
  func testS3b() {
    launch(labArgs)
    sleep(1)
    let top = app.buttons["toTop"], bottom = app.buttons["toBottom"]
    for delay in [0.15, 0.3, 0.6] {
      bottom.tap(); Thread.sleep(forTimeInterval: 0.5)
      drag(200, 520, v: 2000, hold: 0)
      Thread.sleep(forTimeInterval: delay)
      _ = Touch.run(Touch.path([(CGPoint(x: 250, y: 300), 0), (CGPoint(x: 250, y: 300), 0.08)]), name: "catch")
      Thread.sleep(forTimeInterval: 3.0)
    }
    top.tap(); Thread.sleep(forTimeInterval: 0.5)
    drag(500, 300, v: 1500, hold: 0)
    Thread.sleep(forTimeInterval: 3.0)
    drag(200, 520, v: 4000, hold: 0)
    Thread.sleep(forTimeInterval: 3.0)
  }
}

final class UncheckedBox<T>: @unchecked Sendable {
  let value: T
  init(_ v: T) { value = v }
}

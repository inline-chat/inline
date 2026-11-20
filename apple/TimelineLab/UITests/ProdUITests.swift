import XCTest

/// Drives the installed production app (`chat.inline.InlineIOS`, TestFlight) on a device, for traces of
/// real chats. Only looks: opens chats and goes back, never sends, reacts or changes settings unless a
/// test says so. Chats are chosen by `PROD_CHATS` (labels separated by `|`, matched as a prefix of the row's
/// accessibility label); the tree test prints what is on screen to choose them.
final class ProdUITests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = true
    app = XCUIApplication(bundleIdentifier: "chat.inline.InlineIOS")
    app.activate()
    Thread.sleep(forTimeInterval: 1.5)
  }

  func stamp(_ what: String) {
    print("[UITEST] \(what) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
  }

  func shot(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }

  /// The screen's accessibility tree, to pick chats and see where the app is.
  func testProdTree() {
    shot("prod-tree")
    for line in app.debugDescription.split(separator: "\n") { print("[UITEST] tree \(line)") }
  }

  /// Opens each chat in `PROD_CHATS` in turn, `PROD_ROUNDS` times (3), resting 2.5 s in the chat and 1.5 s back
  /// on the list. Taps and back taps are stamped so a trace can be cut per open.
  func testProdChatOpens() {
    let names = (ProcessInfo.processInfo.environment["PROD_CHATS"] ?? "").split(separator: "|").map(String.init)
    let rounds = Int(ProcessInfo.processInfo.environment["PROD_ROUNDS"] ?? "") ?? 3
    guard !names.isEmpty else { return XCTFail("set PROD_CHATS") }
    // A system trace started before the runner enables automation is cut off; this pause lets one
    // start after it (the runner prints `[UITEST] ready`).
    let pause = Double(ProcessInfo.processInfo.environment["PROD_START_PAUSE"] ?? "") ?? 0
    if pause > 0 {
      stamp("ready")
      Thread.sleep(forTimeInterval: pause)
    }
    // Positions are read once, before any traced open: a query during an open runs the app's
    // accessibility tree on its main thread and would be measured as the app's own work. Taps go
    // through SpringBoard's coordinates, which never ask the app anything.
    var centers: [String: CGPoint] = [:]
    for name in names {
      let row = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label BEGINSWITH %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
                              name, XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue,
                              XCUIElement.ElementType.other.rawValue))
        .firstMatch
      guard row.waitForExistence(timeout: 4) else { print("[UITEST] missing \(name)"); continue }
      let f = row.frame
      centers[name] = CGPoint(x: f.midX, y: f.midY)
    }
    let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").coordinate(withNormalizedOffset: .zero)
    func tap(_ point: CGPoint) { screen.withOffset(CGVector(dx: point.x, dy: point.y)).tap() }
    let backPoint = CGPoint(
      x: Double(ProcessInfo.processInfo.environment["PROD_BACK_X"] ?? "") ?? 37,
      y: Double(ProcessInfo.processInfo.environment["PROD_BACK_Y"] ?? "") ?? 39
    )
    for round in 0 ..< rounds {
      for name in names {
        guard let center = centers[name] else { continue }
        stamp("open \(name) round=\(round)")
        tap(center)
        Thread.sleep(forTimeInterval: 2.5)
        stamp("back \(name) round=\(round)")
        tap(backPoint)
        Thread.sleep(forTimeInterval: 1.8)
      }
    }
    shot("prod-opens-end")
    stamp("done")
  }
}

import AppKit
import InlineWebWidget

// Usage: InlineWebWidgetSpike [--auto] [--origin per-widget|shared] [--out <dir>]
let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
  arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

@MainActor
final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
  let auto = arguments.contains("--auto")
  let mode = WidgetOriginMode(rawValue: argument("--origin") ?? "per-widget") ?? .perWidget
  let outDir = URL(fileURLWithPath: argument("--out") ?? FileManager.default.temporaryDirectory.appendingPathComponent("widget-spike").path)
  var window: NSWindow!
  var list: SpikeListController!
  let metrics = SpikeMetrics()

  func applicationDidFinishLaunching(_ notification: Notification) {
    var config = WidgetCoordinator.Configuration()
    config.originMode = mode
    let window = NSWindow(contentRect: NSRect(x: 120, y: 80, width: 760, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Widget spike (\(mode.rawValue))"
    window.appearance = NSAppearance(named: .aqua)
    self.window = window
    let coordinator = WidgetCoordinator(configuration: config, theme: WidgetTheme.current(for: window.effectiveAppearance))
    var rows: [SpikeRow] = []
    let fixtures = SpikeFixture.allCases
    for index in 0..<200 {
      if index % 5 == 2 {
        let fixture = fixtures[(index / 5) % fixtures.count]
        rows.append(.widget(fixture.content(key: "m\(1000 + index)-r1"), fixture))
      } else {
        rows.append(.text("Message \(index): a plain text message between widgets, as in a busy thread."))
      }
    }
    list = SpikeListController(coordinator: coordinator, rows: rows, metrics: metrics)
    window.contentView = list.scrollView
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if auto { Task { await runAuto() } }
  }

  func sleep(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

  var coordinator: WidgetCoordinator { list.coordinator }
  var clip: NSClipView { list.scrollView.contentView }

  func sample(_ label: String) {
    metrics.sample(label, coordinator: coordinator, webViews: coordinator.allWebViews)
  }

  func scroll(to y: CGFloat) {
    clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
    list.scrollView.reflectScrolledClipView(clip)
  }

  func row(of fixture: SpikeFixture, occurrence: Int = 0) -> (Int, WidgetContent) {
    let matches = list.rows.enumerated().compactMap { index, row -> (Int, WidgetContent)? in
      if case let .widget(content, f) = row, f == fixture { return (index, content) }
      return nil
    }
    return matches[occurrence]
  }

  func reveal(_ fixture: SpikeFixture, occurrence: Int = 0) async -> WidgetWebView? {
    let (row, content) = self.row(of: fixture, occurrence: occurrence)
    scroll(to: list.tableView.rect(ofRow: row).minY - 40)
    for _ in 0..<40 {
      await sleep(100)
      if let webView = coordinator.liveWebView(for: content.key), metrics.renders.contains(where: { $0.key == content.key }) { return webView }
    }
    return coordinator.liveWebView(for: content.key)
  }

  func js(_ webView: WKWebViewLike, _ body: String) async -> String {
    do {
      let result = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
      if let result, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed]) {
        return String(decoding: data, as: UTF8.self)
      }
      return String(describing: result)
    } catch {
      return "error: \(error.localizedDescription)"
    }
  }

  /// Delivers a click to the view AppKit would hit-test, as a key window does.
  /// (A background window would spend the first click on activation.)
  func click(_ webView: WidgetWebView, at point: NSPoint) {
    let location = webView.convert(point, to: nil)
    let frameView = window.contentView!.superview!
    let hit = frameView.hitTest(frameView.convert(location, from: nil))
    metrics.checks["clickHitView"] = hit.map { String(describing: type(of: $0)) } ?? "nil"
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        if type == .leftMouseDown { hit?.mouseDown(with: event) } else { hit?.mouseUp(with: event) }
      }
    }
  }

  func runAuto() async {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    await sleep(800)
    sample("baseline (no web views)")

    // First screen: cold web views.
    list.becameIdle()
    await sleep(2500)
    sample("first screen mounted")

    // Page through the list at reading speed.
    let page = clip.bounds.height * 0.9
    for step in 1...10 {
      scroll(to: clip.bounds.origin.y + page)
      await sleep(900)
      if step % 3 == 0 { sample("after page \(step)") }
    }

    // Fast fling: no mounts may start while scrolling.
    let mountsBefore = metrics.mountsWhileScrolling
    for _ in 0..<40 {
      scroll(to: clip.bounds.origin.y + 60)
      await sleep(16)
    }
    metrics.checks["mountsDuringFastScroll"] = String(metrics.mountsWhileScrolling - mountsBefore)
    await sleep(1200)
    sample("after fast scroll")

    // Back to the top: rows should come back with snapshots and measured heights.
    coordinator.unmountAll()
    metrics.resetRowCounters()
    scroll(to: 0)
    await sleep(60)
    metrics.checks["firstFrameOnReturn"] = "\(metrics.rowsWithSnapshot)/\(metrics.rowsConfigured) rows with snapshot, \(metrics.rowsWithMeasuredHeight) with measured height"
    await sleep(1500)

    // Scroll wheel over a live widget must scroll the list.
    if let webView = await reveal(.diagram, occurrence: 1) {
      let pointInWindow = webView.convert(NSPoint(x: webView.bounds.midX, y: 30), to: nil)
      let frameView = window.contentView!.superview!
      let hit = frameView.hitTest(frameView.convert(pointInWindow, from: nil))
      let host = webView.superview?.superview as? WidgetHostView
      metrics.checks["widths"] = "list \(list.contentWidth) host \(host?.contentWidth ?? -1) table \(list.tableView.bounds.width) webViewFlipped \(webView.isFlipped)"
      metrics.checks["hitTestOverWidget"] = hit.map { String(describing: type(of: $0)) } ?? "nil"
      let before = clip.bounds.origin.y
      if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0) {
        let screen = window.convertPoint(toScreen: pointInWindow)
        cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        // Deliver as AppKit would: to the hit view, which must be the web view or inside it.
        if let event = NSEvent(cgEvent: cg), let hit, hit === webView || hit.isDescendant(of: webView) {
          hit.scrollWheel(with: event)
        }
      }
      await sleep(100)
      metrics.checks["scrollWheelOverWidgetMovedList"] = "\(clip.bounds.origin.y != before) (\(Int(before)) -> \(Int(clip.bounds.origin.y)))"
    }

    // Gesture gating, state persistence and actions on the picker.
    if let webView = await reveal(.picker) {
      metrics.checks["copyWithoutGesture"] = await js(webView, "return await inline.copy('spike').then(() => 'ok', e => 'rejected: ' + e.message)")
      metrics.checks["windowKey"] = "\(window.isKeyWindow) appActive \(NSApp.isActive)"
      click(webView, at: NSPoint(x: webView.bounds.maxX - 8, y: 12))
      metrics.checks["gestureRecordedAfterClick"] = String(webView.lastUserInteraction != nil)
      metrics.checks["copyAfterClick"] = await js(webView, "return await inline.copy('spike').then(() => 'ok', e => 'rejected: ' + e.message)")
      metrics.checks["pasteboardAfterCopy"] = list.pasteboard.string(forType: .string) ?? "nil"
      metrics.checks["sendPromptAfterClick"] = await js(webView, "return await inline.sendPrompt('Refine C').then(() => 'ok', e => 'rejected: ' + e.message)")
      metrics.checks["actionAfterClick"] = await js(webView, "return await inline.action('pick', {v: 'C'}).then(() => 'ok', e => 'rejected: ' + e.message)")
      _ = await js(webView, "const el = document.querySelector('input[value=C]'); el.checked = true; el.dispatchEvent(new Event('change', {bubbles: true})); return 'set'")
      let (_, content) = row(of: .picker)
      coordinator.unmount(key: content.key)
      await sleep(400)
      list.becameIdle()
      await sleep(1500)
      if let again = coordinator.liveWebView(for: content.key) {
        metrics.checks["stateAfterRemount"] = await js(again, "const c = document.querySelector('input:checked'); return c ? c.value : 'none'")
      }
      // Theme push without reload.
      let rendersBefore = metrics.renders.count
      let lightForeground = await js(webView, "return getComputedStyle(document.documentElement).getPropertyValue('--foreground')")
      coordinator.setTheme(WidgetTheme.current(for: NSAppearance(named: .darkAqua)!))
      await sleep(300)
      let target = coordinator.liveWebView(for: content.key) ?? webView
      let darkForeground = await js(target, "return getComputedStyle(document.documentElement).getPropertyValue('--foreground')")
      metrics.checks["themePush"] = "\(lightForeground) -> \(darkForeground); reloads: \(metrics.renders.count - rendersBefore)"
      coordinator.setTheme(WidgetTheme.current(for: NSAppearance(named: .aqua)!))
    }

    // Sandbox probes from the page context.
    if let webView = await reveal(.security) {
      metrics.checks["security"] = await js(webView, Self.securityProbe)
    }

    // Visit every fixture once more so each has a snapshot, then unmount all.
    for fixture in SpikeFixture.allCases {
      _ = await reveal(fixture)
      await sleep(300)
    }
    sample("all fixtures visited")
    // Scroll to the end so every visited widget unmounts through the normal snapshot path.
    scroll(to: list.tableView.bounds.height)
    await sleep(1500)
    coordinator.unmountAll()
    await sleep(800)
    sample("all unmounted (pool only)")
    saveSnapshots()

    let report = metrics.report(mode: mode.rawValue)
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      let file = outDir.appendingPathComponent("report-\(mode.rawValue).json")
      try? data.write(to: file)
      print(String(decoding: data, as: UTF8.self))
      print("REPORT \(file.path)")
    }
    NSApp.terminate(nil)
  }

  func saveSnapshots() {
    var summary: [String] = []
    for fixture in SpikeFixture.allCases {
      let (_, content) = row(of: fixture)
      guard let image = coordinator.snapshot(for: content, width: list.contentWidth),
            let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
        summary.append("\(fixture.rawValue): no snapshot")
        continue
      }
      try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("snapshot-\(fixture.rawValue)-\(mode.rawValue).png"))
      let reps = image.representations.map { "\($0.pixelsWide)px" }.joined(separator: ",")
      summary.append("\(fixture.rawValue): \(Int(image.size.width))x\(Int(image.size.height))pt reps[\(reps)] scale \(window.backingScaleFactor), \(Self.distinctColors(rep)) colors")
    }
    metrics.checks["snapshots"] = summary.joined(separator: "; ")
  }

  static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
    var colors = Set<UInt32>()
    let stepX = max(1, rep.pixelsWide / 120), stepY = max(1, rep.pixelsHigh / 120)
    for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
      for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        colors.insert(UInt32(c.redComponent * 31) << 15 | UInt32(c.greenComponent * 31) << 10 | UInt32(c.blueComponent * 31) << 5 | UInt32(c.alphaComponent * 31))
      }
    }
    return colors.count
  }

  static let securityProbe = """
  const out = {};
  const within = (p, ms = 3000) => Promise.race([p, new Promise((_, r) => setTimeout(() => r(new Error("timeout")), ms))]);
  try { await within(fetch("https://example.com")); out.fetch = "ALLOWED"; } catch (e) { out.fetch = "blocked"; }
  try { await within(fetch("inline-widget://w-other/index.html")); out.fetchOtherWidget = "ALLOWED"; } catch (e) { out.fetchOtherWidget = "blocked"; }
  out.xhr = await new Promise(res => { try { const x = new XMLHttpRequest(); x.open("GET", "https://example.com"); x.onload = () => res("ALLOWED"); x.onerror = () => res("blocked"); x.send(); } catch (e) { res("blocked"); } });
  out.websocket = await new Promise(res => { try { const w = new WebSocket("wss://echo.websocket.org"); w.onopen = () => res("ALLOWED"); w.onerror = () => res("blocked"); setTimeout(() => res("timeout"), 3000); } catch (e) { res("blocked"); } });
  out.remoteImage = await new Promise(res => { const i = new Image(); i.onload = () => res("ALLOWED"); i.onerror = () => res("blocked"); i.src = "https://www.apple.com/favicon.ico"; setTimeout(() => res("timeout"), 3000); });
  out.iframe = await new Promise(res => { const f = document.createElement("iframe"); f.srcdoc = "<p>x</p>"; f.onload = () => { let ok = false; try { ok = f.contentDocument && f.contentDocument.body && f.contentDocument.body.textContent === "x"; } catch (e) {} res(ok ? "ALLOWED" : "blocked"); }; document.body.appendChild(f); setTimeout(() => res("blocked (no load)"), 1500); });
  out.windowOpen = (() => { try { return window.open("https://example.com") ? "ALLOWED" : "blocked"; } catch (e) { return "blocked"; } })();
  out.cdnScript = await new Promise(res => { const s = document.createElement("script"); s.src = "https://cdn.jsdelivr.net/npm/canvas-confetti@1.9.3/dist/confetti.browser.min.js"; s.onload = () => res("allowed"); s.onerror = () => res("blocked"); document.head.appendChild(s); setTimeout(() => res("timeout"), 5000); });
  out.nonAllowlistScript = await new Promise(res => { const s = document.createElement("script"); s.src = "https://code.jquery.com/jquery-3.7.1.min.js"; s.onload = () => res("ALLOWED"); s.onerror = () => res("blocked"); document.head.appendChild(s); setTimeout(() => res("timeout"), 5000); });
  try { localStorage.setItem("k", "v"); out.localStorage = "available"; } catch (e) { out.localStorage = "unavailable: " + e.name; }
  try { document.cookie = "a=1"; out.cookie = document.cookie ? "set" : "empty"; } catch (e) { out.cookie = "unavailable"; }
  out.origin = location.origin;
  out.openLinkWithoutGesture = await inline.openLink("https://example.com").then(() => "ALLOWED", e => "rejected: " + e.message);
  out.directHandlerForgedFrame = (() => { try { window.webkit.messageHandlers.inlineWidget.postMessage({jsonrpc: "2.0", method: "inline/copy", params: {text: "x"}}); return "posted (native must gate)"; } catch (e) { return "threw"; } })();
  const before = location.href;
  try { location.href = "https://example.com"; } catch (e) {}
  await new Promise(r => setTimeout(r, 600));
  out.navigation = location.href === before ? "blocked" : "NAVIGATED";
  return JSON.stringify(out);
  """
}

typealias WKWebViewLike = WidgetWebView

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = SpikeAppDelegate()
app.delegate = delegate
app.run()

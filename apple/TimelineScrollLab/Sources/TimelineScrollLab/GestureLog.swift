import AppKit
import QuartzCore

/// `--play <list> --log <file.jsonl>`: for real trackpad gestures over the lab window, the system's own events (a
/// listen-only session event tap: finger events, the lift, the momentum stream, at their times) next to how far the
/// list's content actually travelled after the lift (sampled on the main thread every frame). Settles on real hardware
/// what replayed events cannot: whether NSScrollView follows the momentum stream or runs its own curve.
@MainActor
final class GestureLog: NSObject {
  let lab: LabWindow
  let path: String
  private var tap: CFMachPort?
  private var link: CADisplayLink?
  private var scrollSamples: [(t: Double, y: Double)] = []
  /// Events seen by the tap, (time, phase, momentum phase, dy), for the gesture in progress.
  nonisolated(unsafe) static var events: [(t: Double, phase: Int64, momentum: Int64, dy: Double)] = []
  nonisolated(unsafe) static var lock = NSLock()
  nonisolated(unsafe) static var windowNumber = 0
  private var writeTimer: Timer?
  private let recorder: Recorder
  /// The window's frame in global display coordinates (top-left origin), for events the window server did not tag.
  nonisolated(unsafe) static var frame = CGRect.zero

  init(lab: LabWindow, path: String) {
    self.lab = lab
    self.path = path
    recorder = Recorder(lab: lab)
  }

  func start() {
    Self.windowNumber = lab.window.windowNumber
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    let f = lab.window.frame
    Self.frame = CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let callback: CGEventTapCallBack = { _, _, event, _ in
      let window = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
      if window == GestureLog.windowNumber || (window == 0 && GestureLog.frame.contains(event.location)) {
        let t = Double(event.timestamp) / 1e9
        let entry = (t, event.getIntegerValueField(.scrollWheelEventScrollPhase),
                     event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                     event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        GestureLog.lock.withLock { GestureLog.events.append(entry) }
      }
      return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: callback, userInfo: nil) else {
      print("event tap refused (Input Monitoring)")
      return
    }
    self.tap = tap
    let thread = Thread {
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      CFRunLoopRun()
    }
    thread.start()
    let link = lab.root.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
    writeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.flush() }
    }
    print("logging real gestures over the window to \(path)")
  }

  @objc private func tick(_ link: CADisplayLink) {
    scrollSamples.append((CACurrentMediaTime(), Double(recorder.scrollPosition())))
    if scrollSamples.count > 4000 { scrollSamples.removeFirst(1000) }
  }

  /// Writes each finished gesture (its momentum ended, or quiet for 0.4 s after the lift).
  private func flush() {
    let now = CACurrentMediaTime()
    let events = Self.lock.withLock { Self.events }
    guard let lift = events.lastIndex(where: { $0.phase == 4 || $0.phase == 8 }) else { return }
    let after = events[(lift + 1)...]
    let ended = after.contains { $0.momentum == 3 } || now - events[lift].t > 2.5
    guard ended, now - (events.last?.t ?? now) > 0.4 else { return }
    let liftTime = events[lift].t
    let fingers = events[...lift].filter { $0.phase == 1 || $0.phase == 2 }
    let momentum = after.filter { $0.momentum != 0 }
    func scroll(at t: Double) -> Double? { scrollSamples.last(where: { $0.t <= t })?.y }
    let endTime = (momentum.last?.t ?? liftTime) + 1.0
    let shown = (scroll(at: liftTime) ?? 0) - (scroll(at: min(now, endTime)) ?? 0)
    let record: [String: Any] = [
      "list": lab.subject.kind,
      "lastTracked": fingers.suffix(64).map { [liftTime - $0.t, $0.dy] },
      "momentumSamples": momentum.map { [$0.t - (momentum.first?.t ?? 0), $0.dy] },
      "momentumFirstDelay": (momentum.first?.t ?? liftTime) - liftTime,
      "momentumTravel": momentum.map(\.dy).reduce(0, +),
      "trackedTravel": fingers.map(\.dy).reduce(0, +),
      "listTravelAfterLift": shown,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record), let line = String(data: data, encoding: .utf8) {
      if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
      } else {
        try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
      }
      print(String(format: "gesture: system momentum %.0f pt, list travelled %.0f pt after the lift (%.2f)",
                   record["momentumTravel"] as! Double, shown, shown / max(1, abs(record["momentumTravel"] as! Double))))
    }
    Self.lock.withLock { Self.events.removeAll() }
  }
}

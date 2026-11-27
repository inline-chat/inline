import AppKit
import Foundation

/// Synthetic trackpad events built as the HID system builds them (TimelineMacLab's Synth), posted through the window
/// server to this process so they arrive as a device's do: through the event queue, routed to the window under the
/// location, where responsive scrolling can take them.
enum Synth {
  enum Phase: Int64 {
    case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
  }

  enum Momentum: Int64 {
    case none = 0, begin = 1, `continue` = 2, end = 3
  }

  /// `dy` positive scrolls content down (towards older rows), as a finger moving down with natural scrolling does.
  static func trackpad(_ dy: Double, phase: Phase, momentum: Momentum = .none) -> CGEvent {
    let event = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0
    )!
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    return event
  }

  struct Step: @unchecked Sendable {
    var at: Double
    var event: CGEvent?
    var label: String
    var action: (@MainActor @Sendable () -> Void)?

    init(at: Double, event: CGEvent, label: String) {
      self.at = at
      self.event = event
      self.label = label
    }

    init(at: Double, label: String, action: @escaping @MainActor @Sendable () -> Void) {
      self.at = at
      self.label = label
      self.action = action
    }
  }

  /// A fling: a touch, `count` moves of `speed / 120` at 120 Hz, the lift, then (unless `momentum` is false) the
  /// system's momentum stream at 60 Hz, modelled on real gestures in timeline-gestures.jsonl: the first event carries
  /// the release speed over a 60 Hz interval and each next one about 5% less (time constant ~0.3 s), until under
  /// half a point. Returns the steps and the lift's time.
  static func fling(speed: Double, start: Double = 0, momentum: Bool = true) -> (steps: [Step], lift: Double) {
    var steps: [Step] = []
    var t = start
    let interval = 1.0 / 120
    steps.append(Step(at: t, event: trackpad(0, phase: .mayBegin), label: "mayBegin"))
    t += interval
    for i in 0 ..< 12 {
      steps.append(Step(at: t, event: trackpad(speed / 120, phase: i == 0 ? .began : .changed), label: "move"))
      t += interval
    }
    let lift = t
    steps.append(Step(at: t, event: trackpad(0, phase: .ended), label: "lift"))
    guard momentum else { return (steps, lift) }
    var d = speed / 60
    t += 0.008
    steps.append(Step(at: t, event: trackpad(d, phase: .none, momentum: .begin), label: "momentum"))
    while abs(d * 0.95) >= 0.5 {
      d *= 0.95
      t += 1.0 / 60
      steps.append(Step(at: t, event: trackpad(d, phase: .none, momentum: .continue), label: "momentum"))
    }
    t += 1.0 / 60
    steps.append(Step(at: t, event: trackpad(0, phase: .none, momentum: .end), label: "momentumEnd"))
    return (steps, lift)
  }

  /// A recorded gesture: its tracked events at their recorded spacing, the lift, and the system's momentum events
  /// as recorded (their deltas and times after the first, which came `momentumFirstDelay` after the lift).
  static func replay(_ record: GestureRecord, start: Double = 0, momentumScale: Double? = nil) -> (steps: [Step], lift: Double) {
    var steps: [Step] = []
    let tracked = record.lastTracked.sorted { $0[0] > $1[0] }
    let first = tracked.first?[0] ?? 0
    steps.append(Step(at: start, event: trackpad(0, phase: .mayBegin), label: "mayBegin"))
    for (i, sample) in tracked.enumerated() {
      steps.append(Step(
        at: start + 0.008 + first - sample[0], event: trackpad(sample[1], phase: i == 0 ? .began : .changed),
        label: "move"
      ))
    }
    // LAB_LIFT_PAUSE (seconds): the finger rests that long after its last move before lifting.
    let pause = Double(ProcessInfo.processInfo.environment["LAB_LIFT_PAUSE"] ?? "") ?? 0
    let lift = start + 0.008 + first + 0.0005 + pause
    steps.append(Step(at: lift, event: trackpad(0, phase: .ended), label: "lift"))
    // LAB_TOUCH_AT_END: the touch that ended the recorded stream (Mo's next flick), as a touch that lifts unmoved.
    if ProcessInfo.processInfo.environment["LAB_TOUCH_AT_END"] != nil, let end = record.momentumSamples.last?[0] {
      let at = lift + max(0.001, record.momentumFirstDelay) + end + 1.0 / 60 + 0.004
      steps.append(Step(at: at, event: trackpad(0, phase: .mayBegin), label: "touch"))
      steps.append(Step(at: at + 0.06, event: trackpad(0, phase: .cancelled), label: "touchLift"))
    }
    var momentum = record.momentumSamples
    if let keep = ProcessInfo.processInfo.environment["LAB_MOMENTUM_KEEP"].flatMap(Int.init) {
      momentum = Array(momentum.prefix(keep))
    }
    guard !momentum.isEmpty else { return (steps, lift) }
    let base = lift + max(0.001, record.momentumFirstDelay)
    let scale = momentumScale ?? Double(ProcessInfo.processInfo.environment["LAB_MOMENTUM_SCALE"] ?? "1") ?? 1
    for (i, sample) in momentum.enumerated() {
      steps.append(Step(
        at: base + sample[0], event: trackpad(sample[1] * scale, phase: .none, momentum: i == 0 ? .begin : .continue),
        label: "momentum"
      ))
    }
    steps.append(Step(at: base + (momentum.last?[0] ?? 0) + 1.0 / 60, event: trackpad(0, phase: .none, momentum: .end),
                      label: "momentumEnd"))
    return (steps, lift)
  }
}

struct GestureRecord: Decodable, Sendable {
  var lastTracked: [[Double]]
  var momentumSamples: [[Double]]
  var momentumFirstDelay: Double
  var momentumTravel: Double
  var trackedTravel: Double
  var momentumEvents: Int
  var releaseVelocity: Double

  static func load(_ path: String) -> [GestureRecord] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(GestureRecord.self, from: Data($0.utf8)) }
  }

  /// A real gesture with a full momentum stream: not a lab's synthetic one (round deltas, no momentum) and not one
  /// whose momentum the app's busy main thread merged into a few events.
  var isCleanReal: Bool {
    guard momentumSamples.count >= 12, lastTracked.count >= 3 else { return false }
    let gaps = zip(momentumSamples.dropFirst(), momentumSamples).map { $0[0] - $1[0] }
    return (gaps.max() ?? 1) < 0.03
  }
}

/// Plays steps from a background thread at their times, as a device does: a busy main thread does not hold events
/// back, they queue. Each event is stamped as it goes (velocity is measured from event times) and posted to this
/// process through the window server.
final class EventPlayer: @unchecked Sendable {
  /// pid: posted to this process through the window server; post: the main thread's queue; hid: at the HID tap with
  /// the pointer over the list, as a device's events (routed by the window server to the window under the pointer).
  enum Delivery: String { case pid, post, hid }

  /// The delivery the command line asks for (`--delivery hid`), else pid.
  static var preferred: Delivery {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--delivery"), i + 1 < args.count else { return .pid }
    return Delivery(rawValue: args[i + 1]) ?? .pid
  }
  private let steps: [Synth.Step]
  private let location: CGPoint
  private let windowNumber: Int
  private let delivery: Delivery
  private(set) var startTime: CFTimeInterval = 0
  private(set) var postedTimes: [String: [CFTimeInterval]] = [:]

  static let windowField = CGEventField(rawValue: 51)!
  typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
  nonisolated(unsafe) static let setWindowLocation: SetWindowLocation? = dlsym(dlopen(nil, RTLD_NOW), "CGEventSetWindowLocation")
    .map { unsafeBitCast($0, to: SetWindowLocation.self) }
  private let windowLocation: CGPoint

  init(steps: [Synth.Step], location: CGPoint, windowLocation: CGPoint, windowNumber: Int, delivery: Delivery = .pid) {
    self.windowLocation = windowLocation
    self.steps = steps.sorted { $0.at < $1.at }
    self.location = location
    self.windowNumber = windowNumber
    self.delivery = delivery
  }

  /// Plays everything; returns once the last step is posted (await it from the main actor: the main thread stays free).
  func play() async -> CFTimeInterval {
    await withCheckedContinuation { (done: CheckedContinuation<CFTimeInterval, Never>) in
      let thread = Thread { [self] in
        var savedPointer: CGPoint?
        if delivery == .hid {
          savedPointer = CGEvent(source: nil)?.location
          CGWarpMouseCursorPosition(location)
          usleep(60_000)
        }
        defer { if let savedPointer { CGWarpMouseCursorPosition(savedPointer) } }
        let start = CACurrentMediaTime()
        startTime = start
        for step in steps {
          let target = start + step.at
          while true {
            let now = CACurrentMediaTime()
            let left = target - now
            if left <= 0 { break }
            if left > 0.002 { usleep(useconds_t(min(1000, (left - 0.0015) * 1e6))) }
          }
          if let action = step.action {
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
            continue
          }
          guard let event = step.event else { continue }
          event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
          event.location = location
          event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
          event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
          // The window the event is for (AppKit reads its NSEvent window from this field) and the point in it (top-left
          // origin; AppKit takes locationInWindow from this, not from the global location).
          event.setIntegerValueField(Self.windowField, value: Int64(windowNumber))
          Self.setWindowLocation?(event, windowLocation)
          switch delivery {
            case .pid:
              event.postToPid(getpid())
            case .hid:
              event.post(tap: .cghidEventTap)
            case .post:
              if let ns = NSEvent(cgEvent: event) {
                DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.postEvent(ns, atStart: false) } }
              }
          }
          postedTimes[step.label, default: []].append(CACurrentMediaTime())
        }
        done.resume(returning: start)
      }
      thread.qualityOfService = .userInteractive
      thread.start()
    }
  }
}

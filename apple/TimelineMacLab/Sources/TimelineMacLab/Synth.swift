import AppKit

/// Synthetic wheel and trackpad events, built the way the HID system builds them, so a view's
/// `scrollWheel(with:)` sees the same phases and deltas as from a real device.
enum Synth {
  enum Phase: Int64 {
    case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
  }

  enum Momentum: Int64 {
    case none = 0, begin = 1, `continue` = 2, end = 3
  }

  /// A precise (trackpad) event. `dy` positive scrolls content down (towards the top of a document), as
  /// a finger moving down on a trackpad with natural scrolling does.
  static func trackpad(_ dy: Double, phase: Phase, momentum: Momentum = .none, at point: CGPoint = .zero) -> CGEvent {
    let event = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0
    )!
    event.location = point
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    return event
  }

  /// A precise event moving both ways: `dx` positive moves content right.
  static func trackpadXY(dx: Double, dy: Double, phase: Phase, momentum: Momentum = .none) -> CGEvent {
    let event = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()),
      wheel3: 0
    )!
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded()))
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
    return event
  }

  /// A classic mouse wheel notch: no phase, line units.
  static func wheel(lines: Int32, at point: CGPoint = .zero) -> CGEvent {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
    event.location = point
    return event
  }

  struct Step {
    var at: Double // seconds from the script's start
    var event: CGEvent?
    var label: String
    var action: (@MainActor () -> Void)?

    init(at: Double, event: CGEvent, label: String) {
      self.at = at
      self.event = event
      self.label = label
    }

    init(at: Double, label: String, action: @escaping @MainActor () -> Void) {
      self.at = at
      self.label = label
      self.action = action
    }
  }

  /// A trackpad gesture: `count` moves of `delta` every `interval`, then optional momentum starting at
  /// `momentum` and multiplied by `decay` each `interval` until under 0.5 pt.
  static func gesture(
    start: Double, delta: Double, count: Int, interval: Double = 1.0 / 120, momentum: Double = 0, decay: Double = 0.95,
    label: String
  ) -> [Step] {
    var steps: [Step] = []
    var t = start
    steps.append(Step(at: t, event: trackpad(0, phase: .mayBegin), label: "\(label).mayBegin"))
    t += interval
    steps.append(Step(at: t, event: trackpad(delta, phase: .began), label: "\(label).began"))
    for _ in 1 ..< max(1, count) {
      t += interval
      steps.append(Step(at: t, event: trackpad(delta, phase: .changed), label: label))
    }
    t += interval
    steps.append(Step(at: t, event: trackpad(0, phase: .ended), label: "\(label).ended"))
    if abs(momentum) >= 0.5 {
      var d = momentum
      t += interval
      steps.append(Step(at: t, event: trackpad(d, phase: .none, momentum: .begin), label: "\(label).mbegin"))
      while abs(d * decay) >= 0.5 {
        d *= decay
        t += 1.0 / 60
        steps.append(Step(at: t, event: trackpad(d, phase: .none, momentum: .continue), label: "\(label).m"))
      }
      t += 1.0 / 60
      steps.append(Step(at: t, event: trackpad(0, phase: .none, momentum: .end), label: "\(label).mend"))
    }
    return steps
  }
}

/// Plays steps on the main thread at their times and calls `sink` with each event.
@MainActor
final class Player {
  private var steps: [Synth.Step]
  private var startTime: CFTimeInterval = 0
  private var timer: Timer?
  private let sink: (NSEvent, String) -> Void
  private let delivery: String
  /// Every step's label and when it ran, for the probe.
  var onStep: ((String) -> Void)?
  var onFinish: (() -> Void)?

  /// `delivery`: "direct" hands the event to the sink only (the sink calls the view); "post" queues it on
  /// the app (`NSApp.postEvent`); "pid" posts it through the window server to this process; "hid" posts it
  /// at the HID tap as a device would (needs the window under the cursor).
  init(steps: [Synth.Step], delivery: String = "direct", sink: @escaping (NSEvent, String) -> Void) {
    self.steps = steps.sorted { $0.at < $1.at }
    self.delivery = delivery
    self.sink = sink
  }

  func start() {
    startTime = CACurrentMediaTime()
    let timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.fire() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func fire() {
    let elapsed = CACurrentMediaTime() - startTime
    while let first = steps.first, first.at <= elapsed {
      steps.removeFirst()
      if let action = first.action {
        onStep?(first.label)
        action()
        continue
      }
      guard let cgEvent = first.event else { continue }
      // Stamp the event now: velocity is measured from event times.
      cgEvent.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
      switch delivery {
        case "post":
          if let event = NSEvent(cgEvent: cgEvent) { NSApp.postEvent(event, atStart: false) }
        case "pid":
          cgEvent.postToPid(getpid())
        case "hid":
          cgEvent.post(tap: .cghidEventTap)
        default:
          break
      }
      if let event = NSEvent(cgEvent: cgEvent) { sink(event, first.label) }
    }
    if steps.isEmpty {
      timer?.invalidate()
      timer = nil
      onFinish?()
    }
  }
}

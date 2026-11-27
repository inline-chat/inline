import AppKit

@MainActor
protocol Scenario: AnyObject {
  func run(done: @escaping (Probe) -> Void)
}

@MainActor
enum Scenarios {
  static var all: [String: () -> Scenario] {
    var all: [String: () -> Scenario] = [:]
    for (name, script) in NativeScenario.scripts {
      all["native.\(name)"] = { NativeScenario(name: name, script: script) }
    }
    for (name, script) in EngineScenario.scripts {
      all["engine.\(name)"] = { EngineScenario(name: name, script: script) }
    }
    return all
  }

  static func window(size: NSSize = NSSize(width: 520, height: 760), title: String) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: LabPlacement.origin, size: size), styleMask: [.titled, .resizable],
      backing: .buffered, defer: false
    )
    window.title = title
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.orderFrontRegardless()
    return window
  }
}

/// Scripts the native scroll view and records its clip origin every frame.
@MainActor
final class NativeScenario: Scenario {
  struct Script {
    var start: (NativeReference) -> CGFloat
    var steps: [Synth.Step]
    var tail: Double = 1.6
  }

  static let scripts: [String: Script] = [
    // A slow drag in the middle, then momentum.
    "middle": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 10, count: 20, momentum: 25, label: "g")),
    // Same gesture, momentum events with a much longer tail, and with a much faster start: does the
    // scroll view follow the events' deltas or its own deceleration?
    "middleLongTail": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 10, count: 20, momentum: 25, decay: 0.99, label: "g"), tail: 3),
    "middleFastStart": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 10, count: 20, momentum: 80, decay: 0.95, label: "g")),
    "middleNoMomentum": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 10, count: 20, label: "g")),
    "middleFast": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 30, count: 10, momentum: 60, label: "g")),
    // Release velocity sweep for fitting the deceleration: N pt every 8.3 ms, no momentum events.
    "v4": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 4, count: 20, label: "g"), tail: 2),
    "v8": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 8, count: 20, label: "g"), tail: 2),
    "v16": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 16, count: 20, label: "g"), tail: 2.5),
    "v32": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 32, count: 12, label: "g"), tail: 3),
    "v64": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 64, count: 8, label: "g"), tail: 3.5),
    // Same velocity as v16, but at 60 Hz events with 2x deltas: is velocity read per time or per event?
    "v16at60": Script(start: { _ in 8000 }, steps: Synth.gesture(start: 0.3, delta: 32, count: 10, interval: 1.0 / 60, label: "g"), tail: 2.5),
    // A slowing finger: fast then slow before lifting.
    "slowLift": Script(start: { _ in 8000 }, steps: {
      var s = Synth.gesture(start: 0.3, delta: 20, count: 10, label: "g")
      let end = s.removeLast()
      var t = s.last!.at
      for d: Double in [10, 5, 2, 1, 0, 0] { t += 1.0 / 120; s.append(Synth.Step(at: t, event: Synth.trackpad(d, phase: .changed), label: "g")) }
      s.append(Synth.Step(at: t + 1.0 / 120, event: end.event!, label: end.label))
      return s
    }(), tail: 2),
    // Pull past the top and let go without momentum.
    "pullTop": Script(start: { _ in 0 }, steps: Synth.gesture(start: 0.3, delta: 10, count: 40, label: "pull")),
    // Pull past the top slowly with 2 pt moves (resistance curve at fine resolution).
    "pullTopFine": Script(start: { _ in 0 }, steps: Synth.gesture(start: 0.3, delta: 2, count: 300, label: "pull")),
    // Pull past the bottom.
    "pullBottom": Script(start: { $0.maxOrigin }, steps: Synth.gesture(start: 0.3, delta: -10, count: 40, label: "pull")),
    // Momentum running into the bottom.
    "flingBottom": Script(
      start: { $0.maxOrigin - 400 }, steps: Synth.gesture(start: 0.3, delta: -12, count: 8, momentum: -40, label: "fling"),
      tail: 2
    ),
    // Momentum running into the top.
    "flingTop": Script(
      start: { _ in 400 }, steps: Synth.gesture(start: 0.3, delta: 12, count: 8, momentum: 40, label: "fling"), tail: 2
    ),
    // Three mouse wheel notches.
    "wheel": Script(start: { _ in 8000 }, steps: [
      Synth.Step(at: 0.3, event: Synth.wheel(lines: -1), label: "notch"),
      Synth.Step(at: 0.6, event: Synth.wheel(lines: -1), label: "notch"),
      Synth.Step(at: 0.9, event: Synth.wheel(lines: -3), label: "notch3"),
      Synth.Step(at: 1.2, event: Synth.wheel(lines: 1), label: "notchBack"),
    ]),
    // A fast burst of wheel notches (accelerated wheel).
    "wheelBurst": Script(start: { _ in 8000 }, steps: (0 ..< 12).map {
      Synth.Step(at: 0.3 + Double($0) * 0.03, event: Synth.wheel(lines: -1), label: "notch")
    }),
    // A finger landing on running momentum: mayBegin, then cancelled.
    "catch": Script(start: { _ in 8000 }, steps: {
      var steps = Synth.gesture(start: 0.3, delta: 12, count: 8, momentum: 40, label: "fling")
      let cut = steps.firstIndex { $0.at > 0.55 && $0.label.hasSuffix(".m") } ?? steps.count
      steps = Array(steps[..<cut])
      let t = (steps.last?.at ?? 0.55) + 1.0 / 60
      steps.append(Synth.Step(at: t, event: Synth.trackpad(0, phase: .none, momentum: .end), label: "fling.mend"))
      steps.append(Synth.Step(at: t + 0.001, event: Synth.trackpad(0, phase: .mayBegin), label: "touch.mayBegin"))
      steps.append(Synth.Step(at: t + 0.2, event: Synth.trackpad(0, phase: .cancelled), label: "touch.cancelled"))
      return steps
    }()),
  ]

  let name: String
  let script: Script
  var window: NSWindow?
  var reference: NativeReference?
  var player: Player?
  let probe = Probe()

  init(name: String, script: Script) {
    self.name = name
    self.script = script
  }

  func run(done: @escaping (Probe) -> Void) {
    let window = Scenarios.window(title: "native.\(name)")
    self.window = window
    let reference = NativeReference(frame: window.contentView!.bounds)
    reference.scrollView.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(reference.scrollView)
    self.reference = reference
    reference.scroll(to: script.start(reference))
    probe.note("start", reference.origin)
    probe.note("maxOrigin", reference.maxOrigin)
    probe.note("lineScroll", reference.scrollView.verticalLineScroll)
    probe.read = { ["origin": reference.origin] }
    probe.start(on: reference.scrollView)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
      let delivery = argument("--delivery") ?? "direct"
      let windowNumber = window.windowNumber
      let center = reference.scrollView.convert(NSPoint(x: reference.scrollView.bounds.midX, y: reference.scrollView.bounds.midY), to: nil)
      let screenPoint = window.convertPoint(toScreen: center)
      // CG global coordinates have their origin at the top-left of the main display.
      let mainHeight = NSScreen.screens.first?.frame.height ?? 0
      let globalPoint = CGPoint(x: screenPoint.x, y: mainHeight - screenPoint.y)
      if delivery == "hid" {
        CGWarpMouseCursorPosition(globalPoint)
      }
      let player = Player(steps: script.steps.map { step in
        let step = step
        step.event?.location = globalPoint
        step.event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
        step.event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
        return step
      }, delivery: delivery) { [probe] event, label in
        probe.input(event, label: label)
        if delivery == "direct" { reference.scrollView.scrollWheel(with: event) }
        probe.sample(["afterEvent": 1])
      }
      player.onFinish = { [probe] in
        DispatchQueue.main.asyncAfter(deadline: .now() + self.script.tail) {
          probe.stop()
          probe.note("end", reference.origin)
          done(probe)
        }
      }
      self.player = player
      player.start()
    }
  }
}

import AppKit
import QuartzCore
import ScrollTimeline
import TimelineCore

/// Does responsive scrolling engage for the prototype, with events posted through the window server? A fling with
/// momentum, and a 150 ms main-thread stall in its momentum: if the scroll view moves its clip layer off the main
/// thread, the layer's model position changes during the stall (sampled from a background thread every 2 ms).
@MainActor
enum Probe {
  final class LayerBox: @unchecked Sendable {
    let layer: CALayer
    init(_ layer: CALayer) { self.layer = layer }
  }

  final class Sampler: @unchecked Sendable {
    let box: LayerBox
    private let lock = NSLock()
    private var running = true
    private(set) var samples: [(t: Double, y: Double)] = []
    init(_ box: LayerBox) { self.box = box }

    func start() {
      let thread = Thread { [self] in
        while true {
          lock.lock()
          let go = running
          lock.unlock()
          if !go { break }
          let y = Double(box.layer.bounds.origin.y)
          let t = CACurrentMediaTime()
          lock.lock()
          samples.append((t, y))
          lock.unlock()
          usleep(2000)
        }
      }
      thread.qualityOfService = .userInteractive
      thread.start()
    }

    func stop() -> [(t: Double, y: Double)] {
      lock.lock()
      running = false
      let out = samples
      lock.unlock()
      return out
    }
  }

  static func run() async {
    print("screen capture allowed: \(ScreenWatch.isAvailable)")
    for screen in NSScreen.screens {
      print("screen \(screen.localizedName): \(Int(screen.frame.width))×\(Int(screen.frame.height)) @\(screen.maximumFramesPerSecond) Hz ×\(screen.backingScaleFactor)")
    }
    for delivery in [EventPlayer.Delivery.pid] {
      for kind in ["plain", "nsscroll"] {
        await probe(kind: kind, delivery: delivery)
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
  }

  static func probe(kind: String, delivery: EventPlayer.Delivery) async {
    let lab = LabWindow(kind: kind, count: 3000)
    defer { lab.close() }
    let ids = lab.chat.ids
    lab.subject.apply(scroll: .to(ids[ids.count / 2], .center))
    try? await Task.sleep(for: .milliseconds(400))
    let layer: CALayer
    if let scroll = lab.subject as? ScrollSubject {
      layer = scroll.list.clip.layer!
      print("[\(kind)] concurrent-scrolling compatible: \(scroll.list.isConcurrentScrollingCompatible.map(String.init) ?? "?"), clip \(type(of: scroll.list.clip)), layer-backed \(scroll.list.clip.layer != nil)")
    } else if let plain = lab.subject as? PlainSubject {
      layer = plain.scrollView.contentView.layer!
    } else {
      layer = (lab.subject as! EngineSubject).list.content.layer!
    }
    var events: [String: Int] = [:]
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      let key = event.momentumPhase.isEmpty ? "finger" : "momentum"
      if events.isEmpty {
        print("  first event: window \(event.window?.title ?? "nil") number \(event.windowNumber) loc \(event.locationInWindow) phase \(event.phase.rawValue) dy \(event.scrollingDeltaY) precise \(event.hasPreciseScrollingDeltas); lab window \(lab.window.windowNumber) frame \(lab.window.frame); hit \(lab.window.contentView?.hitTest(event.locationInWindow).map { String(describing: type(of: $0)) } ?? "nil")")
      }
      events[key, default: 0] += 1
      return event
    }
    let sampler = Sampler(LayerBox(layer))
    var fling = Synth.fling(speed: -5000)
    let stallAt = fling.lift + 0.15
    var stall: (CFTimeInterval, CFTimeInterval)?
    fling.steps.append(Synth.Step(at: stallAt, label: "stall") {
      let a = CACurrentMediaTime()
      while CACurrentMediaTime() - a < 0.15 {}
      stall = (a, CACurrentMediaTime())
    })
    let watch = ScreenWatch(geometry: lab.screenGeometry)
    await watch.start(windowNumber: lab.window.windowNumber, size: lab.window.frame.size,
                      scale: lab.window.backingScaleFactor, rate: lab.window.screen?.maximumFramesPerSecond ?? 60)
    try? await Task.sleep(for: .milliseconds(200))
    if !arguments.contains("--no-sampler") { sampler.start() }
    let player = lab.player(fling.steps, delivery: delivery)
    let start = await player.play()
    try? await Task.sleep(for: .milliseconds(1500))
    let samples = sampler.stop()
    let screen = await watch.stop()
    if let (a, b) = stall {
      var changed = 0
      for (prev, frame) in zip(screen, screen.dropFirst()) where frame.t > a + 0.01 && frame.t < b {
        if frame.edges != prev.edges { changed += 1 }
      }
      let inStall = (0 ..< changed).map { $0 }
      var line = "  timeline (ms from stall start: first edge, or - unchanged):"
      for (prev, frame) in zip(screen, screen.dropFirst()) where frame.t > a - 0.08 && frame.t < b + 0.12 {
        line += String(format: " %+.0f:%@", (frame.t - a) * 1000, frame.edges == prev.edges ? "-" : String(format: "%.0f", frame.edges.first ?? -1))
      }
      print(line)
      var layerLine = "  layer y (ms: y):"
      for sample in samples where sample.t > a - 0.08 && sample.t < b + 0.12 && Int(sample.t * 1000) % 10 < 2 {
        layerLine += String(format: " %+.0f:%.0f", (sample.t - a) * 1000, sample.y)
      }
      print(layerLine)
      print("  screen: \(screen.count) frames, \(inStall.count) frames that moved during the stall, worst blank \(Int(screen.map(\.blank).max() ?? 0)) pt, textless rows max \(screen.map(\.textless).max() ?? 0)\(watch.failure.map { ", failure \($0)" } ?? "")")
    }
    if let monitor { NSEvent.removeMonitor(monitor) }
    let lift = start + fling.lift
    var line = "[\(kind) via \(delivery.rawValue)] events seen on main: \(events)"
    if let (a, b) = stall {
      let during = samples.filter { $0.t > a + 0.004 && $0.t < b - 0.002 }
      let moved = (during.last?.y ?? 0) - (during.first?.y ?? 0)
      let before = samples.filter { $0.t > lift && $0.t < a }
      let movedBefore = (before.last?.y ?? 0) - (before.first?.y ?? 0)
      let rateBefore = before.count > 1 ? movedBefore / ((before.last!.t - before.first!.t)) : 0
      line += String(format: "; layer moved %.0f pt in the %.0f ms stall (%d samples), %.0f pt/s before it", moved,
                     (b - a) * 1000, during.count, rateBefore)
    } else {
      line += "; stall did not run"
    }
    let total = (samples.last?.y ?? 0) - (samples.first?.y ?? 0)
    line += String(format: "; total %.0f pt", total)
    if let scroll = lab.subject as? ScrollSubject { line += "; " + scroll.notes }
    print(line)
  }
}

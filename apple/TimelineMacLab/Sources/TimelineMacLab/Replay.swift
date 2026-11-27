import AppKit
import TimelineAppKit

/// `--replay <timeline-gestures.jsonl>`: real trackpad gestures from a Dev build's log, each played (same deltas, same
/// intervals) into a plain NSScrollView, next to the fling the list played for it in the app. The reference for how
/// far a real flick should travel: prints one line per gesture and a summary.
@MainActor
enum GestureReplay {
  struct Record: Decodable {
    var lastTracked: [[Double]]
    var releaseVelocity: Double
    var gain: Double
    var flingTravel: Double?
    var flingDuration: Double?
    var momentumTravel: Double
    var trackedTravel: Double
  }

  static func run(path: String) async {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      print("cannot read \(path)")
      return
    }
    let records = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
    NativeReference.FlippedView.responsive = false
    let window = Scenarios.window(title: "replay")
    let reference = NativeReference(frame: window.contentView!.bounds)
    window.contentView!.addSubview(reference.scrollView)
    print("gesture  events  ours: velocity×gain → travel   NSScrollView: travel   ratio   system momentum")
    var ratios: [(speed: Double, ratio: Double)] = []
    for (index, record) in records.enumerated() where record.lastTracked.count >= 3 {
      reference.scroll(to: reference.maxOrigin / 2)
      try? await Task.sleep(for: .milliseconds(200))
      let native = await play(record, into: reference)
      let ours = record.flingTravel ?? 0
      let ratio = abs(native) > 1 ? ours / native : .nan
      if abs(native) > 1, record.flingTravel != nil { ratios.append((abs(record.releaseVelocity), ratio)) }
      print(String(
        format: "%4d  %4d   %7.0f×%.2f → %7.0f pt   %7.0f pt   %5.2f   %7.0f pt",
        index, record.lastTracked.count, record.releaseVelocity, record.gain, ours, native, ratio, record.momentumTravel
      ))
    }
    if !ratios.isEmpty {
      let sorted = ratios.map(\.ratio).sorted()
      print(String(format: "ours / NSScrollView: median %.2f (n=%d, %.2f…%.2f)", sorted[sorted.count / 2], sorted.count,
                   sorted.first!, sorted.last!))
    }
  }

  /// Plays the gesture's events at their recorded intervals; the travel after the lift, in the list's sign (positive:
  /// content moved down), once the scroll view has been still for 0.3 s.
  private static func play(_ record: Record, into reference: NativeReference) async -> Double {
    // [seconds before the lift, delta], oldest first.
    let tracked = record.lastTracked.sorted { $0[0] > $1[0] }
    let first = tracked[0][0]
    var steps: [Synth.Step] = [Synth.Step(at: 0, event: Synth.trackpad(0, phase: .mayBegin), label: "mayBegin")]
    for (i, sample) in tracked.enumerated() {
      steps.append(Synth.Step(
        at: 0.008 + first - sample[0], event: Synth.trackpad(sample[1], phase: i == 0 ? .began : .changed), label: "move"
      ))
    }
    steps.append(Synth.Step(at: 0.008 + first, event: Synth.trackpad(0, phase: .ended), label: "lift"))
    var atLift: CGFloat?
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      let player = Player(steps: steps, delivery: "direct") { event, label in
        reference.scrollView.scrollWheel(with: event)
        if label == "lift" { atLift = reference.origin }
      }
      player.onFinish = { done.resume() }
      player.start()
      holder = player
    }
    var last = reference.origin
    var still = 0.0
    var waited = 0.0
    while still < 0.3, waited < 5 {
      try? await Task.sleep(for: .milliseconds(20))
      waited += 0.02
      let now = reference.origin
      still = abs(now - last) < 0.01 ? still + 0.02 : 0
      last = now
    }
    // A flipped document: the origin grows as the content moves up, the list's negative direction.
    return Double((atLift ?? last) - last)
  }

  private static var holder: Player?
}

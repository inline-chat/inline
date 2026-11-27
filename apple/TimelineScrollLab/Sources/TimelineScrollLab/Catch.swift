import AppKit
import QuartzCore

/// A touch mid-fling, measured on screen (ScreenCaptureKit): what the window server shows around the catch, not the
/// presentation layer. A stop decided on the main thread lands a frame or more after it was read, while the render
/// server keeps playing the fling; a stop at the presented position then steps back by that much motion.
/// `--compare catch [--subjects engine-flight,nsscroll]`.
extension Compare {
  static func catches() async {
    let speeds: [Double] = [2500, 5000]
    let delays: [Double] = [0.12, 0.3]
    for kind in argument("--subjects")?.split(separator: ",").map(String.init) ?? ["engine-flight"] {
      let run = Run(kind: kind, count: 3000, rowCost: 1)
      await run.wait(0.3)
      for speed in speeds {
        for delay in delays {
          for repeatIndex in 0 ..< 3 {
            await run.centre()
            await run.begin()
            let fling = Synth.fling(speed: speed)
            let touch = fling.lift + delay
            // A touch ends the system's momentum stream: nothing of it after the touch.
            var steps = fling.steps.filter { $0.at < touch }
            steps.append(Synth.Step(at: touch, event: Synth.trackpad(0, phase: .mayBegin), label: "touch"))
            steps.append(Synth.Step(at: touch + 0.3, event: Synth.trackpad(0, phase: .cancelled), label: "touchLift"))
            let t0 = await run.play(steps)
            _ = await run.untilRest()
            await run.end()
            report(run: run, name: "catch \(Int(speed)) +\(Int(delay * 1000))ms #\(repeatIndex)", touch: t0 + touch)
          }
        }
      }
      run.close()
    }
  }

  /// Screen steps around the touch: the fling's direction from the steps before it; a step against it after the touch
  /// is the jump back; the motion after the touch is how far the content went on before it stopped.
  private static func report(run: Run, name: String, touch: CFTimeInterval) {
    let frames = run.screen.filter { $0.t >= touch - 0.12 && $0.t <= touch + 0.4 }
    let motions = ScreenMotion.motions(frames) { run.presentedMotion($0, $1) }
    let before = motions.filter { $0.t <= touch && abs($0.d) > 0.25 }.map(\.d)
    guard let direction = before.last.map({ $0 > 0 ? 1.0 : -1.0 }) else {
      print(String(format: "%-28@ %-14@ no motion before the touch", name as NSString, run.kind as NSString))
      return
    }
    let after = motions.filter { $0.t > touch }
    let back = after.map { -$0.d * direction }.filter { $0 > 0.25 }.max() ?? 0
    let onward = after.map { $0.d * direction }.filter { $0 > 0 }.reduce(0, +)
    let lastMove = after.last(where: { abs($0.d) > 0.25 }).map { ($0.t - touch) * 1000 } ?? 0
    let speedAtTouch = (before.suffix(2).map(abs).reduce(0, +) / Double(max(1, before.suffix(2).count)))
      * Double(run.lab.window.screen?.maximumFramesPerSecond ?? 60)
    let steps = motions.filter { $0.t > touch - 0.05 && $0.t < touch + 0.1 }
      .map { String(format: "%+.1f@%.0f", $0.d * direction, ($0.t - touch) * 1000) }.joined(separator: " ")
    print(String(
      format: "%-28@ %-14@ speed %5.0f pt/s  back %5.1f pt  onward %5.1f pt  last move +%3.0f ms  | %@",
      name as NSString, run.kind as NSString, speedAtTouch, back, onward, lastMove, steps as NSString
    ))
    fflush(stdout)
  }
}

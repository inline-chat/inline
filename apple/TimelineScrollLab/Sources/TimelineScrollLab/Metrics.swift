import Foundation

/// The numbers of one run, from the presentation-layer frames (main thread, every display frame), the window
/// server's frames (ScreenCaptureKit, every composited frame, whatever the main thread does) and the main run loop.
struct RunNumbers: Codable {
  var subject: String
  var scenario: String
  /// Content travel from the lift to rest (presentation), positive towards older rows.
  var travel: Double = 0
  /// The system's own travel for the events played (finger + momentum deltas), for reference.
  var eventTravel: Double = 0
  /// Worst blank strip in the usable area: presentation layers / screen pixels (points).
  var blank: Double = 0
  var screenBlank: Double = 0
  /// Frames with any blank (presentation / screen).
  var blankFrames = 0
  var screenBlankFrames = 0
  /// Most message rows on screen without their current text in a frame (presentation: not drawn since configured);
  /// most rows on screen with no text pixel at all (screen).
  var undrawn = 0
  var undrawnFrames = 0
  var screenTextless = 0
  var screenTextlessFrames = 0
  /// Frames recorded (display link) and composited (screen) while moving.
  var frames = 0
  var screenFrames = 0
  /// Screen frames that showed no motion while the content was moving (a frozen frame: stall or missed commit).
  var frozenFrames = 0
  /// Longest time the screen showed no motion while moving (ms).
  var longestFreeze: Double = 0
  /// Smoothness from the screen's frame-to-frame motion: p95 and worst change of speed between consecutive frames, as
  /// a share of the speed (0: even), and the same in pt/s.
  var jerkP95: Double = 0
  var jerkMax: Double = 0
  var speedChangeP95: Double = 0
  /// Main thread busy per display frame while moving (ms): median, p95, worst.
  var busyP50: Double = 0
  var busyP95: Double = 0
  var busyMax: Double = 0
  /// The list's own passes per display frame (ms, average) and the host's row work (ms per frame).
  var listPerFrame: Double = 0
  var hostPerFrame: Double = 0
  /// Visible jumps: frames whose screen motion differs from both neighbours' by more than 24 pt (a leap of content).
  var jumps = 0
  var worstJump: Double = 0
  var notes: String = ""
  var extra: [String: Double] = [:]
  /// Raw screen motion per captured frame from the lift (pt, positive towards older) and its time after the lift (ms).
  var screenSteps: [Double] = []
  var screenTimes: [Double] = []
  /// Brake re-bakes of the forked engine, ms after the lift.
  var brakeTimes: [Double] = []
}

enum Stats {
  static func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[index]
  }

  static func median(_ values: [Double]) -> Double { percentile(values, 0.5) }
}

/// Frame-to-frame motion on screen: for each pair of captured frames, the shift that best aligns their row edges,
/// searched near what the presentation layers predict (rows are periodic enough to alias otherwise).
enum ScreenMotion {
  /// `predict(t0, t1)`: content motion between two times from the presentation samples (positive: down).
  static func motions(_ frames: [ScreenFrame], predict: (Double, Double) -> Double?) -> [(t: Double, dt: Double, d: Double)] {
    var out: [(Double, Double, Double)] = []
    for (prev, cur) in zip(frames, frames.dropFirst()) {
      guard prev.edges.count >= 2, cur.edges.count >= 2 else { continue }
      if prev.edges == cur.edges {
        out.append((cur.t, cur.t - prev.t, 0))
        continue
      }
      let predicted = predict(prev.t, cur.t) ?? 0
      var best: (score: Int, d: Double, error: Double) = (-1, 0, .infinity)
      var d = predicted - 80
      while d <= predicted + 80 {
        var score = 0
        var error = 0.0
        for edge in cur.edges {
          let target = edge - d
          if let match = prev.edges.min(by: { abs($0 - target) < abs($1 - target) }), abs(match - target) <= 1.5 {
            score += 1
            error += abs(match - target)
          }
        }
        if score > best.score || (score == best.score && abs(d - predicted) < abs(best.d - predicted)) {
          best = (score, d, error)
        }
        d += 0.5
      }
      // Refine: the mean offset of matched edges.
      var sum = 0.0
      var n = 0.0
      for edge in cur.edges {
        let target = edge - best.d
        if let match = prev.edges.min(by: { abs($0 - target) < abs($1 - target) }), abs(match - target) <= 1.5 {
          sum += edge - match
          n += 1
        }
      }
      let shift = n > 0 && Double(best.score) >= Double(min(cur.edges.count, prev.edges.count)) * 0.5 ? sum / n : predicted
      out.append((cur.t, cur.t - prev.t, shift))
    }
    return out
  }
}

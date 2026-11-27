import AppKit
import QuartzCore

/// Samples a value every display frame and records the events a scenario plays, then writes JSON.
@MainActor
final class Probe {
  struct Sample: Encodable { var t: Double; var values: [String: Double] }
  struct Input: Encodable { var t: Double; var label: String; var dy: Double; var precise: Bool }

  private(set) var samples: [Sample] = []
  var inputs: [Input] = []
  private(set) var notes: [String: Double] = [:]
  private(set) var texts: [String: String] = [:]
  private let t0 = CACurrentMediaTime()
  private var link: CADisplayLink?
  private var lastTimestamp: CFTimeInterval = 0
  private(set) var frameGaps: [Double] = []
  var read: (() -> [String: Double])?

  var now: Double { CACurrentMediaTime() - t0 }

  func start(on view: NSView) {
    let link = view.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick(_ link: CADisplayLink) {
    if lastTimestamp > 0 { frameGaps.append((link.timestamp - lastTimestamp) * 1000) }
    lastTimestamp = link.timestamp
    sample()
  }

  func sample(_ extra: [String: Double] = [:]) {
    var values = read?() ?? [:]
    for (k, v) in extra { values[k] = v }
    samples.append(Sample(t: now, values: values))
  }

  func input(_ event: NSEvent, label: String) {
    inputs.append(Input(t: now, label: label, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas))
  }

  func note(_ key: String, _ value: Double) { notes[key] = value }
  func text(_ key: String, _ value: String) { texts[key] = value }

  func write(to path: String) {
    struct Out: Encodable {
      var samples: [Sample]; var inputs: [Input]; var notes: [String: Double]; var texts: [String: String]
      var frameGaps: [Double]
    }
    let out = Out(samples: samples, inputs: inputs, notes: notes, texts: texts, frameGaps: frameGaps)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(out)
    try! data.write(to: URL(fileURLWithPath: path))
  }
}

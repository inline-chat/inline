import Foundation
import TimelineAppKit
import TimelineCore

/// `--calcdump <out.json>`: AppKit's momentum calculator (through TimelineAppKit's `NativeScrolling.path`, no ends),
/// travel every 5 ms for release speeds from 100 to 100,000 pt/s, for fitting NSScrollView's curve offline.
@MainActor
enum CalcDump {
  static func run(path: String) {
    var out: [[String: Any]] = []
    var v = 100.0
    while v <= 100_000 {
      let p = NativeScrolling.path(velocity: v, lower: nil, upper: nil, viewportHeight: 650, interval: 0.005)
      out.append(["velocity": v, "interval": p.interval, "positions": p.positions.map { ($0 * 10).rounded() / 10 },
                  "native": NativeScrolling.hasNativeMomentum])
      v *= 1.15
    }
    let data = try! JSONSerialization.data(withJSONObject: out)
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(out.count) curves to \(path), native calculator: \(NativeScrolling.hasNativeMomentum)")
  }
}

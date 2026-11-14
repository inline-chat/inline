import QuartzCore
import UIKit

/// S3L: a long virtual list (`-rows 2000`) whose rows are realised only around the engine's predicted position
/// (`± margin`, default 160 pt), with deliberately expensive creation (`-rowcost <ms>`, default 2). No reuse.
@MainActor
final class VirtualList {
  var heights: [CGFloat] = []
  var tops: [CGFloat] = []
  var realised: [Int: UIView] = [:]
  /// Index of the first row in the original numbering (prepends make it negative) — only used for labels/colours.
  var firstID = 0
  let margin = CGFloat(Double(Lab.arg("margin") ?? "160") ?? 160)
  let costMs = Double(Lab.arg("rowcost") ?? "2") ?? 2
  var seed: UInt64 = 0x9E37_79B9

  init(count: Int) {
    heights = (0..<count).map { _ in nextHeight() }
    rebuildTops()
  }

  func nextHeight() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(44 + Int(Double(seed >> 33) / Double(1 << 31) * 140))
  }

  func rebuildTops() {
    tops = []; tops.reserveCapacity(heights.count)
    var y: CGFloat = 0
    for h in heights { tops.append(y); y += h }
  }

  var total: CGFloat { (tops.last ?? 0) + (heights.last ?? 0) }

  func firstIndex(atOrAfter y: CGFloat) -> Int {
    var lo = 0, hi = tops.count - 1
    while lo < hi { let m = (lo + hi + 1) / 2; if tops[m] <= y { lo = m } else { hi = m - 1 } }
    return lo
  }

  func makeRow(_ i: Int, width: CGFloat) -> UIView {
    let t0 = CACurrentMediaTime()
    while (CACurrentMediaTime() - t0) * 1000 < costMs {} // deliberately expensive creation
    let id = i + firstID
    let hueBands: [(Double, Double)] = [(0.0, 0.22), (0.48, 0.72)]
    let band = hueBands[abs(id) % 2]
    let hue = band.0 + Double(abs(id * 7919) % 100) / 100 * (band.1 - band.0)
    let v = UIView(frame: CGRect(x: 8, y: tops[i], width: width - 16, height: heights[i] - 6))
    v.backgroundColor = UIColor(hue: hue, saturation: 0.35, brightness: 0.93, alpha: 1)
    v.layer.cornerRadius = 10
    let label = UILabel(frame: CGRect(x: 10, y: 6, width: 200, height: 18))
    label.text = "row \(id)"
    label.font = .systemFont(ofSize: 13)
    label.textColor = .darkGray
    v.addSubview(label)
    return v
  }

  /// Realise rows covering [pos - margin, pos + clipH + margin]; drop the rest. Logs creations and an in-process
  /// coverage check of the *presentation* window (a blank band would show here only if the model lags the screen).
  func realise(around pos: CGFloat, lab: LabView, frame: Int) {
    guard !heights.isEmpty else { return }
    let clipH = lab.clipHeight
    let lo = firstIndex(atOrAfter: max(0, pos - margin))
    var hi = firstIndex(atOrAfter: min(total, pos + clipH + margin))
    hi = min(heights.count - 1, hi)
    var created = 0
    let t0 = CACurrentMediaTime()
    if lo <= hi {
      for i in lo...hi where realised[i] == nil {
        let v = makeRow(i, width: lab.bounds.width)
        lab.content.addSubview(v)
        realised[i] = v
        created += 1
      }
    }
    for (i, v) in realised where i < lo || i > hi { v.removeFromSuperview(); realised[i] = nil }
    let ms = (CACurrentMediaTime() - t0) * 1000
    // coverage of what is on screen now (presentation), in-process
    let pres = (lab.content.layer.presentation() ?? lab.content.layer).bounds.origin.y
    let a = firstIndex(atOrAfter: max(0, pres)), b = firstIndex(atOrAfter: min(total, pres + clipH))
    var missing = 0
    if a <= b { for i in a...min(b, heights.count - 1) where realised[i] == nil { missing += 1 } }
    if created > 0 || missing > 0 {
      lab.probe.mark(String(format: "realise pos=%.1f pres=%.1f rows %d..%d created=%d (%.1f ms) missingOnScreen=%d", pos, pres, lo, hi, created, ms, missing), frame: frame)
    }
  }

  /// Insert `count` older rows at the top; returns the height added (offsets grow by it).
  func prepend(count: Int, lab: LabView) -> CGFloat {
    let new = (0..<count).map { _ in nextHeight() }
    let dy = new.reduce(0, +)
    heights = new + heights
    firstID -= count
    rebuildTops()
    var moved: [Int: UIView] = [:]
    for (i, v) in realised { v.frame.origin.y += dy; moved[i + count] = v }
    realised = moved
    lab.contentHeight = total
    return dy
  }
}

extension LabView {
  /// S3L setup: replace the 60 static rows by a virtual list.
  func setupVirtualList() {
    guard let n = Int(Lab.arg("rows") ?? "2000") else { return }
    for r in rows { r.removeFromSuperview() }
    rows = []
    let list = VirtualList(count: n)
    virtualList = list
    contentHeight = list.total
    Lab.log("virtual list rows=\(n) height=\(contentHeight) margin=\(list.margin) rowcost=\(list.costMs)ms")
  }
}

extension LabView {
  /// SIMULATOR/logic run (`-autofling 1`, engine C only): programmatic flings, a catch, and a prepend mid-fling.
  /// No touches involved, so this checks realisation coverage, re-bake continuity and catch position only.
  func runAutoFling() async {
    await Lab.sleep(1.5)
    guard let c = engine as? CustomEngine else { Lab.log("autofling: engine is not C"); return }
    for v in [-2000.0, -4000.0, -6000.0] {
      c.setOffset(maxOffset); await Lab.sleep(0.4)
      probe.mark("autofling v=\(v)", frame: frameIndex)
      c.fling(v: CGFloat(v)); await Lab.sleep(3.8)
    }
    for delay in [0.15, 0.35, 0.8] {
      c.setOffset(maxOffset); await Lab.sleep(0.4)
      probe.mark("autocatch after \(delay)", frame: frameIndex)
      c.fling(v: -3000); await Lab.sleep(delay)
      c.stopFling(reason: "auto")
      await Lab.sleep(1.0)
    }
    // prepend while flinging toward the top: start 4500 pt from the top so the predicted position crosses 3000
    s3PrependArmedOverride = true
    c.setOffset(4500); await Lab.sleep(0.4)
    probe.mark("autofling prepend v=-4000", frame: frameIndex)
    c.fling(v: -4000); await Lab.sleep(4.0)
    probe.save()
    Lab.write("autofling.done", "done")
    Lab.flushEvents()
  }
}

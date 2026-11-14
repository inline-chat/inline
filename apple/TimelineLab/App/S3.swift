import Darwin
import QuartzCore
import UIKit

/// S3 scroll engines over the same rows. Offsets are content.bounds.origin.y; 0 = oldest top, max = newest at bottom.
@MainActor
protocol ScrollEngine: AnyObject {
  var name: String { get }
  func layoutChanged()
  func tick(_ link: CADisplayLink)
  func offsets() -> (model: Double, presentation: Double)
  func resetToBottom()
  func setOffset(_ y: CGFloat)
  func teardown()
  /// The offset the engine will show at media time `t` (C: from its baked path; U/R: the model value).
  func predictedOffset(at t: CFTimeInterval) -> CGFloat
  /// Content was inserted above the current position (offsets grew by `dy`): keep the visual position and the motion.
  func contentShifted(by dy: CGFloat)
}

/// Main-thread CPU time (user + system) of the calling thread, in milliseconds.
func threadCPUms() -> Double {
  var info = thread_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
  let port = mach_thread_self()
  defer { mach_port_deallocate(mach_task_self_, port) }
  let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
  }
  guard kr == KERN_SUCCESS else { return .nan }
  return Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
    + Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
}

/// Passive recogniser that records raw touch samples (including coalesced touches) for velocity estimators.
final class VelocitySampler: UIGestureRecognizer {
  var samples: [(t: Double, y: Double)] = []
  var onEnd: (([(t: Double, y: Double)]) -> Void)?
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    samples.removeAll()
    if let t = touches.first { samples.append((t.timestamp, Double(t.location(in: view).y))) }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesMoved(touches, with: event)
    guard let t = touches.first else { return }
    for c in event.coalescedTouches(for: t) ?? [t] { samples.append((c.timestamp, Double(c.location(in: view).y))) }
    if samples.count > 400 { samples.removeFirst(samples.count - 400) }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesEnded(touches, with: event)
    if let t = touches.first { samples.append((t.timestamp, Double(t.location(in: view).y))) }
    onEnd?(samples)
    state = .failed
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { super.touchesCancelled(touches, with: event); state = .failed }

  /// Finger velocities (pt/s, +down) by several estimators.
  static func estimators(_ s: [(t: Double, y: Double)]) -> [String: Double] {
    var out: [String: Double] = [:]
    guard s.count >= 2, let last = s.last else { return out }
    // last two distinct timestamps
    if let prev = s.dropLast().last(where: { $0.t < last.t - 0.0005 }) { out["last"] = (last.y - prev.y) / (last.t - prev.t) }
    for win in [0.03, 0.05, 0.08, 0.1, 0.15] {
      let w = s.filter { $0.t >= last.t - win }
      guard w.count >= 2 else { continue }
      let n = Double(w.count)
      let mt = w.map { $0.t }.reduce(0, +) / n, my = w.map { $0.y }.reduce(0, +) / n
      let num = w.map { ($0.t - mt) * ($0.y - my) }.reduce(0, +)
      let den = w.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
      if den > 0 { out["lsq\(Int(win * 1000))"] = num / den }
      if let f = w.first, last.t > f.t { out["avg\(Int(win * 1000))"] = (last.y - f.y) / (last.t - f.t) }
    }
    // trailing stationary samples dropped (XCUITest drags end with repeated positions), then least squares
    var moving = s
    while moving.count > 2, let l = moving.last, let p = moving.dropLast().last, abs(l.y - p.y) < 0.5 { moving.removeLast() }
    if let ml = moving.last {
      for win in [0.05, 0.08, 0.1] {
        let w = moving.filter { $0.t >= ml.t - win }
        if w.count >= 2 {
          let n = Double(w.count)
          let mt = w.map { $0.t }.reduce(0, +) / n, my = w.map { $0.y }.reduce(0, +) / n
          let num = w.map { ($0.t - mt) * ($0.y - my) }.reduce(0, +)
          let den = w.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
          if den > 0 { out["mv\(Int(win * 1000))"] = num / den }
        }
      }
    }
    // peak: max-magnitude 50 ms least-squares slope among windows ending in the last 150 ms
    var peak = 0.0
    for endIdx in s.indices where s[endIdx].t >= last.t - 0.15 {
      let e = s[endIdx]
      let w = s.filter { $0.t <= e.t && $0.t >= e.t - 0.05 }
      guard w.count >= 3 else { continue }
      let n = Double(w.count)
      let mt = w.map { $0.t }.reduce(0, +) / n, my = w.map { $0.y }.reduce(0, +) / n
      let num = w.map { ($0.t - mt) * ($0.y - my) }.reduce(0, +)
      let den = w.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
      if den > 0, abs(num / den) > abs(peak) { peak = num / den }
    }
    out["peak"] = peak
    // exponential moving average of instantaneous velocities (alpha 0.8 on the newest)
    var ema: Double?
    for i in 1..<s.count where s[i].t > s[i - 1].t + 0.0005 {
      let v = (s[i].y - s[i - 1].y) / (s[i].t - s[i - 1].t)
      ema = ema.map { 0.2 * $0 + 0.8 * v } ?? v
    }
    if let ema { out["ema"] = ema }
    out["samples"] = Double(s.count)
    return out
  }
}

extension LabView {
  var clipHeight: CGFloat { bounds.height - composerH }
  var maxOffset: CGFloat { max(0, contentHeight - clipHeight) }

  func setupS3() {
    guard mode.hasPrefix("S3") else { return }
    let listEngine: Int = ["U": 0, "C": 1, "R": 2][Lab.arg("engine") ?? "C"] ?? 1
    let byMode: [String: Int] = ["S3U": 0, "S3C": 1, "S3R": 2, "S3L": listEngine]
    engineChip.selectedSegmentIndex = byMode[mode] ?? 1
    engineChip.addTarget(self, action: #selector(engineChanged), for: .valueChanged)
    engineChip.backgroundColor = UIColor(white: 1, alpha: 0.9)
    engineChip.accessibilityIdentifier = "engineChip"
    addSubview(engineChip)
    DispatchQueue.main.async { self.installEngine(["U", "C", "R"][self.engineChip.selectedSegmentIndex]) }
    for (i, (title, id)) in [("Top", "toTop"), ("Bottom", "toBottom")].enumerated() {
      let b = UIButton(type: .system)
      b.setTitle(title, for: .normal)
      b.backgroundColor = UIColor(white: 1, alpha: 0.9)
      b.accessibilityIdentifier = id
      b.frame = CGRect(x: 200, y: 60 + CGFloat(i) * 36, width: 70, height: 30)
      b.addAction(UIAction { [weak self] _ in
        guard let self else { return }
        self.s3ResetWork?.cancel()
        self.engine?.setOffset(id == "toTop" ? 0 : self.maxOffset)
        self.probe.mark("button \(id)", frame: self.frameIndex)
      }, for: .touchUpInside)
      addSubview(b)
      s3Buttons.append(b)
    }
    // raw touch samples for velocity estimators, on every engine (passive)
    let vs = VelocitySampler(target: nil, action: nil)
    vs.cancelsTouchesInView = false
    vs.delaysTouchesEnded = false
    vs.delegate = self
    vs.onEnd = { [weak self] samples in
      guard let self else { return }
      let est = VelocitySampler.estimators(samples)
      self.lastVelocityEstimates = est
      self.probe.mark("VEL finger(+down) " + est.keys.sorted().map { String(format: "%@=%.1f", $0, est[$0]!) }.joined(separator: " "), frame: self.frameIndex)
    }
    addGestureRecognizer(vs)
  }

  @objc func engineChanged() { installEngine(["U", "C", "R"][engineChip.selectedSegmentIndex]) }

  func installEngine(_ kind: String) {
    engine?.teardown()
    content.layer.removeAllAnimations()
    switch kind {
    case "U": engine = DriverEngine(lab: self)
    case "R": engine = ReferenceEngine(lab: self)
    default: engine = CustomEngine(lab: self)
    }
    Lab.log("S3 engine installed: \(engine!.name)")
    probe.mark("engine \(engine!.name)", frame: frameIndex)
    setNeedsLayout()
  }

  /// Called by engines when a fling starts (finger lifted).
  func s3FlingStarted(velocity: Double) {
    probe.mark("fling start v=\(velocity)", frame: frameIndex)
    s3FlingCPU0 = threadCPUms(); s3FlingWall0 = CACurrentMediaTime(); s3TickWork = 0; s3TickCount = 0
    if Lab.arg("hitch") == "1" {
      for (i, t) in [0.10, 0.30, 0.50].enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
          guard let self else { return }
          let o = self.engine?.offsets()
          self.probe.mark(String(format: "stall%d begin cyP=%.2f cy=%.2f", i, o?.presentation ?? .nan, o?.model ?? .nan), frame: self.frameIndex)
          let t0 = CACurrentMediaTime()
          while CACurrentMediaTime() - t0 < 0.080 {}
          let o2 = self.engine?.offsets()
          self.probe.mark(String(format: "stall%d end cyP=%.2f cy=%.2f", i, o2?.presentation ?? .nan, o2?.model ?? .nan), frame: self.frameIndex)
        }
      }
    }
    if Lab.arg("prepend") == "1" || s3PrependArmedOverride { s3PrependArmed = true; s3PrependArmedOverride = false }
    s3ResetWork?.cancel()
    let noReset = Lab.arg("noreset") == "1"
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let o = self.engine?.offsets()
      let cpu = threadCPUms() - self.s3FlingCPU0, wall = CACurrentMediaTime() - self.s3FlingWall0
      self.probe.mark(String(format: "settled cy=%.2f cyP=%.2f mainCPU=%.1fms over %.2fs (%.1f%%) tickWork=%.1fms in %d ticks", o?.model ?? .nan, o?.presentation ?? .nan, cpu, wall, 100 * cpu / (wall * 1000), self.s3TickWork * 1000, self.s3TickCount), frame: self.frameIndex)
      if !noReset {
        self.engine?.resetToBottom()
        self.probe.mark("reset", frame: self.frameIndex)
      }
      self.probe.save()
      Lab.flushEvents()
    }
    s3ResetWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
  }

  /// Per tick (S3): realise rows around the engine's predicted position, and prepend older content when armed.
  func s3Tick(_ l: CADisplayLink) {
    let t0 = CACurrentMediaTime()
    if let e = engine {
      let target = l.targetTimestamp
      let pos = e.predictedOffset(at: target)
      if s3PrependArmed, pos < 3000, let list = virtualList {
        s3PrependArmed = false
        let before = e.predictedOffset(at: target)
        let dy = list.prepend(count: 300, lab: self)
        e.contentShifted(by: dy)
        let after = e.predictedOffset(at: target)
        probe.mark(String(format: "prepend continuity: predicted before %.2f + dy %.2f = %.2f, after re-bake %.2f (error %.2f)", before, dy, before + dy, after, after - (before + dy)), frame: frameIndex)
        probe.mark(String(format: "prepend 300 rows dy=%.1f at predicted %.1f", dy, pos), frame: frameIndex)
      }
      virtualList?.realise(around: e.predictedOffset(at: target), lab: self, frame: frameIndex)
    }
    s3TickWork += CACurrentMediaTime() - t0
    s3TickCount += 1
  }
}

// MARK: - U: UIScrollView used only as a physics driver

final class DriverEngine: NSObject, ScrollEngine, UIScrollViewDelegate {
  let name = "U"
  weak var lab: LabView?
  let driver = UIScrollView()
  /// content offset = driver.contentOffset.y - base
  var base: CGFloat = 500_000
  let recenterThreshold = CGFloat(Double(Lab.arg("recenter") ?? "0") ?? 0)
  var recenters = 0
  var lastY: CGFloat = 0

  init(lab: LabView) {
    self.lab = lab
    super.init()
    driver.backgroundColor = .clear
    driver.showsVerticalScrollIndicator = false
    driver.contentInsetAdjustmentBehavior = .never
    driver.delegate = self
    driver.keyboardDismissMode = .interactive
    driver.decelerationRate = .normal
    lab.insertSubview(driver, aboveSubview: lab.clip)
    layoutChanged()
    resetToBottom()
  }

  func layoutChanged() {
    guard let lab else { return }
    let w = lab.bounds.width
    lab.content.frame = CGRect(x: 0, y: 0, width: w, height: lab.clipHeight)
    driver.frame = CGRect(x: 0, y: 0, width: w, height: max(0, lab.bounds.height - lab.composerH - lab.effectiveKB))
    applyLimits()
  }

  /// Real limits only at the true ends: min offset = base (content 0), max = base + maxOffset.
  func applyLimits() {
    guard let lab else { return }
    let cur = driver.contentOffset
    driver.contentInset = UIEdgeInsets(top: -base, left: 0, bottom: 0, right: 0)
    driver.contentSize = CGSize(width: driver.bounds.width, height: base + lab.maxOffset + driver.bounds.height)
    if driver.contentOffset != cur { driver.contentOffset = cur }
  }

  func scrollViewDidScroll(_ s: UIScrollView) {
    guard let lab else { return }
    let y = s.contentOffset.y - base
    lab.content.bounds.origin.y = y
    if recenterThreshold > 0, (s.isDecelerating || s.isTracking), y > 0, y < lab.maxOffset {
      let center = base + lab.maxOffset / 2
      let drift = s.contentOffset.y - center
      if abs(drift) > recenterThreshold {
        // move the virtual window: base and offset shift together, content y unchanged
        let shift = round(drift)
        base -= shift
        applyLimits()
        let before = s.contentOffset.y
        s.contentOffset.y = before - shift
        recenters += 1
        lab.probe.mark(String(format: "recenter #%d shift=%.0f decel=%d", recenters, shift, s.isDecelerating ? 1 : 0), frame: lab.frameIndex)
      }
    }
  }

  func scrollViewWillEndDragging(_ s: UIScrollView, withVelocity v: CGPoint, targetContentOffset t: UnsafeMutablePointer<CGPoint>) {
    lab?.probe.mark(String(format: "U willEndDragging v=%.3f pt/ms target=%.1f", v.y, t.pointee.y - base), frame: lab?.frameIndex ?? 0)
  }
  func scrollViewDidEndDragging(_ s: UIScrollView, willDecelerate d: Bool) {
    lab?.s3FlingStarted(velocity: Double(s.panGestureRecognizer.velocity(in: s).y))
  }
  func scrollViewDidEndDecelerating(_ s: UIScrollView) { lab?.probe.mark("U didEndDecelerating", frame: lab?.frameIndex ?? 0) }

  func tick(_ link: CADisplayLink) {}
  func offsets() -> (model: Double, presentation: Double) {
    guard let lab else { return (.nan, .nan) }
    return (Double(lab.content.bounds.origin.y), Double((lab.content.layer.presentation() ?? lab.content.layer).bounds.origin.y))
  }
  func resetToBottom() {
    guard let lab else { return }
    driver.setContentOffset(CGPoint(x: 0, y: base + lab.maxOffset), animated: false)
  }
  func setOffset(_ y: CGFloat) { driver.setContentOffset(CGPoint(x: 0, y: base + y), animated: false) }
  func teardown() { driver.removeFromSuperview() }
  func predictedOffset(at t: CFTimeInterval) -> CGFloat { lab?.content.bounds.origin.y ?? 0 }
  /// Prepend: re-base so the same driver offset maps to y + dy; contentOffset itself is untouched (deceleration keeps going).
  func contentShifted(by dy: CGFloat) {
    base -= dy
    applyLimits()
    let wasDecel = driver.isDecelerating
    scrollViewDidScroll(driver)
    lab?.probe.mark(String(format: "U rebase dy=%.1f decelerating before=%d after=%d", dy, wasDecel ? 1 : 0, driver.isDecelerating ? 1 : 0), frame: lab?.frameIndex ?? 0)
  }
}

// MARK: - C: own pan + rubber band + render-server deceleration keyframes

final class TouchDown: UIGestureRecognizer {
  var onDown: (() -> Void)?
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event); onDown?()
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { super.touchesEnded(touches, with: event); state = .failed }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { super.touchesCancelled(touches, with: event); state = .failed }
}

/// Constants for C. Defaults are the values fitted to UIScrollView recordings (raw/S3, s3_U/s3_R/s3b_*):
/// deceleration 0.998/ms; UIKit stops at ~10–12 pt/s with 0.5 pt rounding; a fling that hits an end decays its
/// overscroll velocity at ~29/s (peak ≈ v/29) then returns critically damped with ω ≈ 11.3/s; a released pull
/// returns critically damped with ω ≈ 12.2/s (0.65 s to < 0.5 pt).
@MainActor
struct CPhysics {
  var decel = Double(Lab.arg("cdecel") ?? "0.998") ?? 0.998
  var stopV = Double(Lab.arg("cstop") ?? "10") ?? 10            // pt/s
  var hitK = Double(Lab.arg("chitk") ?? "29") ?? 29             // 1/s, overscroll velocity decay after hitting an end
  var hitReturnW = Double(Lab.arg("chitret") ?? "11.3") ?? 11.3 // 1/s
  var pullReturnW = Double(Lab.arg("cpullret") ?? "12.2") ?? 12.2
  var vEstimator = Lab.arg("vest") ?? "pan"
  var v0Boost = Double(Lab.arg("v0boost") ?? "1.0") ?? 1.0
  var legacy = Lab.arg("clegacy") == "1"                        // previous run's constants (5 pt/s stop, soft bounce)
}

final class CustomEngine: NSObject, ScrollEngine, UIGestureRecognizerDelegate {
  let name = "C"
  weak var lab: LabView?
  let pan = UIPanGestureRecognizer()
  let down = TouchDown()
  var startY: CGFloat = 0
  var flinging = false
  var phys = CPhysics()
  /// Baked path: values at `dt` spacing starting at media time `pathStart` (also velocities, pt/s).
  var path: [Double] = []
  var pathV: [Double] = []
  var pathStart: CFTimeInterval = 0
  let dt = 1.0 / 120.0

  init(lab: LabView) {
    self.lab = lab
    super.init()
    pan.addTarget(self, action: #selector(onPan(_:)))
    pan.delegate = self
    down.cancelsTouchesInView = false
    down.delaysTouchesEnded = false
    down.delegate = self
    down.onDown = { [weak self] in self?.stopFling(reason: "touch") }
    lab.clip.isUserInteractionEnabled = true
    lab.clip.addGestureRecognizer(pan)
    lab.clip.addGestureRecognizer(down)
    layoutChanged()
    resetToBottom()
    Lab.log("C physics \(phys.summary)")
  }

  func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

  func layoutChanged() {
    guard let lab else { return }
    lab.content.frame = CGRect(x: 0, y: 0, width: lab.bounds.width, height: lab.clipHeight)
  }

  var d: CGFloat { lab?.clipHeight ?? 500 }
  func rubber(_ x: CGFloat) -> CGFloat { (1 - 1 / (x * 0.55 / d + 1)) * d }
  func unrubber(_ r: CGFloat) -> CGFloat { let q = min(0.999, r / d); return (1 / (1 - q) - 1) * d / 0.55 }

  func clampRubber(_ raw: CGFloat) -> CGFloat {
    guard let lab else { return raw }
    if raw < 0 { return -rubber(-raw) }
    if raw > lab.maxOffset { return lab.maxOffset + rubber(raw - lab.maxOffset) }
    return raw
  }

  var flingActive: Bool { flinging && CACurrentMediaTime() < pathStart + Double(path.count) * dt }

  func stopFling(reason: String) {
    guard let lab, flingActive || lab.content.layer.animation(forKey: "fling") != nil else { return }
    let p = (lab.content.layer.presentation() ?? lab.content.layer).bounds.origin.y
    let predicted = predictedOffset(at: CACurrentMediaTime())
    lab.content.layer.removeAnimation(forKey: "fling")
    lab.content.bounds.origin.y = p
    flinging = false
    lab.probe.mark(String(format: "C fling stopped (%@) at presentation %.2f (path-predicted now %.2f, diff %.2f)", reason, p, predicted, predicted - p), frame: lab.frameIndex)
  }

  @objc func onPan(_ g: UIPanGestureRecognizer) {
    guard let lab else { return }
    let t = g.translation(in: lab).y
    switch g.state {
    case .began:
      stopFling(reason: "pan")
      let y = lab.content.bounds.origin.y
      if y < 0 { startY = -unrubber(-y) } else if y > lab.maxOffset { startY = lab.maxOffset + unrubber(y - lab.maxOffset) } else { startY = y }
      startY += t
    case .changed:
      CATransaction.begin(); CATransaction.setDisableActions(true)
      lab.content.bounds.origin.y = clampRubber(startY - t)
      CATransaction.commit()
    case .ended, .cancelled:
      let panV = -Double(g.velocity(in: lab).y)
      var v = panV
      if phys.vEstimator != "pan", let est = lab.lastVelocityEstimates[phys.vEstimator] { v = -est }
      v *= phys.v0Boost
      lab.probe.mark(String(format: "C release panV=%.1f used(%@ ×%.3f)=%.1f", panV, phys.vEstimator, phys.v0Boost, v), frame: lab.frameIndex)
      fling(v: CGFloat(v))
    default: break
    }
  }

  /// Bakes position(t) from (y0, v0 in pt/s) with the current limits.
  func bake(y0: Double, v0: Double) -> (values: [Double], vels: [Double]) {
    guard let lab else { return ([y0], [0]) }
    let maxY = Double(lab.maxOffset)
    var y = y0, v = v0
    var values = [y], vels = [v]
    let lnr = log(phys.decel) * 1000 // per second
    enum Phase { case decel, over(bound: Double), ret(bound: Double, x0: Double, t: Double, w: Double) }
    var phase: Phase = .decel
    if y < 0 || y > maxY {
      let b = y < 0 ? 0 : maxY
      phase = ((y - b) * v > 0) ? .over(bound: b) : .ret(bound: b, x0: y - b, t: 0, w: phys.pullReturnW)
    }
    var steps = 0
    while steps < 2400 {
      steps += 1
      switch phase {
      case .decel:
        let r = exp(lnr * dt)
        let ny = y + v * (r - 1) / lnr
        v *= r
        if ny < 0 || ny > maxY {
          y = ny; phase = .over(bound: ny < 0 ? 0 : maxY)
        } else { y = ny }
        if abs(v) < phys.stopV, case .decel = phase {
          values.append((y * 2).rounded() / 2); vels.append(0)
          return (values, vels)
        }
      case .over(let b):
        if phys.legacy {
          // previous model: critically damped spring with the hit velocity (k = 0.25/ms²)
          let w = 15.8
          let x = y - b
          let a = -w * w * x - 2 * w * v
          v += a * dt; y += v * dt
          if abs(y - b) < 0.1 && abs(v) < 5 { values.append(b); vels.append(0); return (values, vels) }
        } else {
          let r = exp(-phys.hitK * dt)
          y += v * (r - 1) / -phys.hitK
          v *= r
          if abs(v) < 5 { phase = .ret(bound: b, x0: y - b, t: 0, w: phys.hitReturnW) }
        }
      case .ret(let b, let x0, let t, let w):
        let nt = t + dt
        let x = x0 * (1 + w * nt) * exp(-w * nt)
        let nx = y
        y = b + x
        v = (y - nx) / dt
        phase = .ret(bound: b, x0: x0, t: nt, w: w)
        if abs(x) < 0.25 { values.append(b); vels.append(0); return (values, vels) }
      }
      values.append(y); vels.append(v)
    }
    return (values, vels)
  }

  func fling(v v0: CGFloat) {
    guard let lab else { return }
    let y0 = Double(lab.content.bounds.origin.y)
    if phys.legacy { phys.stopV = 5 }
    var vStart = Double(v0)
    if !phys.legacy, (y0 < 0 && vStart < 0) || (y0 > Double(lab.maxOffset) && vStart > 0) { vStart = 0 } // pull release: return directly
    let (values, vels) = bake(y0: y0, v0: vStart)
    let dur = Double(values.count - 1) * dt
    lab.probe.mark(String(format: "C fling v0=%.1f pt/s travel=%.1f dur=%.3f samples=%d stopV=%.1f", Double(v0), values.last! - values[0], dur, values.count, phys.stopV), frame: lab.frameIndex)
    lab.s3FlingStarted(velocity: Double(v0))
    play(values: values, vels: vels)
  }

  func play(values: [Double], vels: [Double]) {
    guard let lab else { return }
    let dur = Double(values.count - 1) * dt
    path = values; pathV = vels
    pathStart = CACurrentMediaTime()
    guard dur > 0.02 else { lab.content.bounds.origin.y = CGFloat(values.last!); flinging = false; return }
    let a = CAKeyframeAnimation(keyPath: "bounds.origin.y")
    a.values = values.map { NSNumber(value: $0) }
    a.duration = dur
    a.calculationMode = .linear
    a.beginTime = lab.content.layer.convertTime(pathStart, from: nil)
    a.isRemovedOnCompletion = true
    CATransaction.begin(); CATransaction.setDisableActions(true)
    lab.content.bounds.origin.y = CGFloat(values.last!)
    lab.content.layer.add(a, forKey: "fling")
    CATransaction.commit()
    flinging = true
  }

  func predictedOffset(at t: CFTimeInterval) -> CGFloat {
    guard let lab else { return 0 }
    guard flingActive, !path.isEmpty else { return lab.content.bounds.origin.y }
    let f = max(0, (t - pathStart) / dt)
    let i = Int(f)
    if i >= path.count - 1 { return CGFloat(path.last!) }
    let w = f - Double(i)
    return CGFloat(path[i] * (1 - w) + path[i + 1] * w)
  }

  func velocity(at t: CFTimeInterval) -> Double {
    guard flingActive, !pathV.isEmpty else { return 0 }
    let i = min(pathV.count - 1, max(0, Int((t - pathStart) / dt)))
    return pathV[i]
  }

  /// Re-bake from the current sampled position and velocity, shifted by dy, with the new limits.
  func contentShifted(by dy: CGFloat) {
    guard let lab else { return }
    let now = CACurrentMediaTime()
    if flingActive {
      let y = Double(predictedOffset(at: now)) + Double(dy)
      let v = velocity(at: now)
      lab.content.layer.removeAnimation(forKey: "fling")
      let (values, vels) = bake(y0: y, v0: v)
      lab.probe.mark(String(format: "C re-bake after shift %.1f: from %.1f v=%.1f → end %.1f (%d samples)", Double(dy), y, v, values.last!, values.count), frame: lab.frameIndex)
      play(values: values, vels: vels)
    } else {
      lab.content.bounds.origin.y += dy
    }
  }

  func tick(_ link: CADisplayLink) {}
  func offsets() -> (model: Double, presentation: Double) {
    guard let lab else { return (.nan, .nan) }
    return (Double(lab.content.bounds.origin.y), Double((lab.content.layer.presentation() ?? lab.content.layer).bounds.origin.y))
  }
  func resetToBottom() {
    guard let lab else { return }
    lab.content.layer.removeAnimation(forKey: "fling")
    flinging = false
    lab.content.bounds.origin.y = lab.maxOffset
  }
  func setOffset(_ y: CGFloat) {
    lab?.content.layer.removeAnimation(forKey: "fling")
    flinging = false
    lab?.content.bounds.origin.y = y
  }
  func teardown() {
    lab?.clip.removeGestureRecognizer(pan)
    lab?.clip.removeGestureRecognizer(down)
  }
}

extension CPhysics {
  var summary: String { "decel=\(decel) stopV=\(stopV) hitK=\(hitK) hitReturnW=\(hitReturnW) pullReturnW=\(pullReturnW) vest=\(vEstimator) v0Boost=\(v0Boost) legacy=\(legacy)" }
}

// MARK: - R: plain UIScrollView reference with the same rows

final class ReferenceEngine: NSObject, ScrollEngine, UIScrollViewDelegate {
  let name = "R"
  weak var lab: LabView?
  let scroll = UIScrollView()

  init(lab: LabView) {
    self.lab = lab
    super.init()
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.delegate = self
    scroll.decelerationRate = .normal
    scroll.keyboardDismissMode = .interactive
    lab.clip.addSubview(scroll)
    lab.content.removeFromSuperview()
    scroll.addSubview(lab.content)
    layoutChanged()
    resetToBottom()
  }

  func layoutChanged() {
    guard let lab else { return }
    scroll.frame = CGRect(x: 0, y: 0, width: lab.bounds.width, height: lab.clipHeight)
    lab.content.frame = CGRect(x: 0, y: 0, width: lab.bounds.width, height: lab.contentHeight)
    lab.content.bounds.origin.y = 0
    scroll.contentSize = CGSize(width: lab.bounds.width, height: lab.contentHeight)
  }
  func scrollViewDidEndDragging(_ s: UIScrollView, willDecelerate d: Bool) {
    lab?.s3FlingStarted(velocity: Double(s.panGestureRecognizer.velocity(in: s).y))
  }
  func scrollViewWillEndDragging(_ s: UIScrollView, withVelocity v: CGPoint, targetContentOffset t: UnsafeMutablePointer<CGPoint>) {
    lab?.probe.mark(String(format: "R willEndDragging v=%.3f pt/ms target=%.1f", v.y, t.pointee.y), frame: lab?.frameIndex ?? 0)
  }
  func tick(_ link: CADisplayLink) {}
  func offsets() -> (model: Double, presentation: Double) {
    (Double(scroll.contentOffset.y), Double((scroll.layer.presentation() ?? scroll.layer).bounds.origin.y))
  }
  func resetToBottom() {
    guard let lab else { return }
    scroll.setContentOffset(CGPoint(x: 0, y: max(0, lab.contentHeight - scroll.bounds.height)), animated: false)
  }
  func setOffset(_ y: CGFloat) { scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
  func teardown() {
    guard let lab else { return }
    lab.content.removeFromSuperview()
    lab.clip.addSubview(lab.content)
    scroll.removeFromSuperview()
  }
  func predictedOffset(at t: CFTimeInterval) -> CGFloat { scroll.contentOffset.y }
  func contentShifted(by dy: CGFloat) {
    guard let lab else { return }
    layoutChanged()
    scroll.contentOffset.y += dy
    lab.probe.mark(String(format: "R shifted dy=%.1f decelerating=%d", Double(dy), scroll.isDecelerating ? 1 : 0), frame: lab.frameIndex)
  }
}

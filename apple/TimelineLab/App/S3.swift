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
}

extension LabView {
  var clipHeight: CGFloat { bounds.height - composerH }
  var maxOffset: CGFloat { max(0, contentHeight - clipHeight) }

  func setupS3() {
    guard mode.hasPrefix("S3") else { return }
    engineChip.selectedSegmentIndex = ["S3U": 0, "S3C": 1, "S3R": 2][mode] ?? 1
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
      b.frame = CGRect(x: 200 + CGFloat(i) * 0, y: 60 + CGFloat(i) * 36, width: 70, height: 30)
      b.addAction(UIAction { [weak self] _ in
        guard let self else { return }
        self.s3ResetWork?.cancel()
        self.engine?.setOffset(id == "toTop" ? 0 : self.maxOffset)
        self.probe.mark("button \(id)", frame: self.frameIndex)
      }, for: .touchUpInside)
      addSubview(b)
      s3Buttons.append(b)
    }
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
    s3ResetWork?.cancel()
    let noReset = Lab.arg("noreset") == "1"
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let o = self.engine?.offsets()
      self.probe.mark(String(format: "settled cy=%.2f cyP=%.2f", o?.model ?? .nan, o?.presentation ?? .nan), frame: self.frameIndex)
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
        // silently move the virtual window: base and offset shift together, content y unchanged
        base += 0 // base is tied to the true ends here; recentring = re-basing the virtual origin
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

final class CustomEngine: NSObject, ScrollEngine, UIGestureRecognizerDelegate {
  let name = "C"
  weak var lab: LabView?
  let pan = UIPanGestureRecognizer()
  let down = TouchDown()
  var startY: CGFloat = 0
  var flinging = false

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
  }

  func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

  func layoutChanged() {
    guard let lab else { return }
    lab.content.frame = CGRect(x: 0, y: 0, width: lab.bounds.width, height: lab.clipHeight)
  }

  var d: CGFloat { lab?.clipHeight ?? 500 }
  func rubber(_ x: CGFloat) -> CGFloat { (1 - 1 / (x * 0.55 / d + 1)) * d }
  /// inverse of rubber: overshoot distance that yields displayed r
  func unrubber(_ r: CGFloat) -> CGFloat { let q = min(0.999, r / d); return (1 / (1 - q) - 1) * d / 0.55 }

  func clampRubber(_ raw: CGFloat) -> CGFloat {
    guard let lab else { return raw }
    if raw < 0 { return -rubber(-raw) }
    if raw > lab.maxOffset { return lab.maxOffset + rubber(raw - lab.maxOffset) }
    return raw
  }

  func stopFling(reason: String) {
    guard let lab, flinging || lab.content.layer.animation(forKey: "fling") != nil else { return }
    let p = (lab.content.layer.presentation() ?? lab.content.layer).bounds.origin.y
    lab.content.layer.removeAnimation(forKey: "fling")
    lab.content.bounds.origin.y = p
    flinging = false
    lab.probe.mark(String(format: "C fling stopped (%@) at %.2f", reason, p), frame: lab.frameIndex)
  }

  @objc func onPan(_ g: UIPanGestureRecognizer) {
    guard let lab else { return }
    let t = g.translation(in: lab).y
    switch g.state {
    case .began:
      stopFling(reason: "pan")
      // continue from the displayed position; map rubber-banded value back to raw space
      let y = lab.content.bounds.origin.y
      if y < 0 { startY = -unrubber(-y) } else if y > lab.maxOffset { startY = lab.maxOffset + unrubber(y - lab.maxOffset) } else { startY = y }
      startY += t // translation already accumulated at recognition
    case .changed:
      CATransaction.begin(); CATransaction.setDisableActions(true)
      lab.content.bounds.origin.y = clampRubber(startY - t)
      CATransaction.commit()
    case .ended, .cancelled:
      let v = -g.velocity(in: lab).y // content-offset velocity, pt/s
      fling(v: v)
    default: break
    }
  }

  /// Precompute UIKit-like deceleration (0.998/ms) + bounce, play as one keyframe animation on the render server.
  func fling(v v0: CGFloat) {
    guard let lab else { return }
    let maxY = lab.maxOffset
    var y = lab.content.bounds.origin.y
    var v = v0 / 1000 // pt/ms
    let dt: CGFloat = 1000.0 / 120.0 // ms per sample
    var values: [CGFloat] = [y]
    var inBounce = y < 0 || y > maxY
    var springV: CGFloat = 0
    if inBounce { springV = 0 }
    let k: CGFloat = 0.00025, c: CGFloat = 2 * sqrt(0.00025) // per-ms^2 critically damped spring (≈0.45 s settle)
    var steps = 0
    while steps < 600 {
      steps += 1
      if !inBounce {
        let r = pow(0.998, dt)
        let ny = y + v * (r - 1) / log(0.998) // exact integral of v·0.998^t over dt ms
        v *= r
        if ny < 0 || ny > maxY {
          // hit an end: carry velocity into a spring anchored at the bound
          let bound: CGFloat = ny < 0 ? 0 : maxY
          y = ny; inBounce = true; springV = v
          _ = bound
        } else { y = ny }
        values.append(y)
        if abs(v) < 0.005 { break } // < 5 pt/s
      } else {
        let bound: CGFloat = y < maxY / 2 ? 0 : maxY
        let x = y - bound
        let a = -k * x - c * springV
        springV += a * dt
        y += springV * dt
        values.append(y)
        if abs(y - bound) < 0.1 && abs(springV) < 0.005 { values.append(bound); break }
      }
    }
    let end = values.last!
    let dur = Double(values.count - 1) * Double(dt) / 1000
    lab.probe.mark(String(format: "C fling v0=%.1f pt/s travel=%.1f dur=%.3f samples=%d", v0, end - values[0], dur, values.count), frame: lab.frameIndex)
    lab.s3FlingStarted(velocity: Double(v0))
    guard dur > 0.02 else { return }
    let a = CAKeyframeAnimation(keyPath: "bounds.origin.y")
    a.values = values.map { NSNumber(value: Double($0)) }
    a.duration = dur
    a.calculationMode = .linear
    a.isRemovedOnCompletion = true
    CATransaction.begin(); CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in self?.flinging = false }
    lab.content.bounds.origin.y = end
    lab.content.layer.add(a, forKey: "fling")
    CATransaction.commit()
    flinging = true
  }

  func tick(_ link: CADisplayLink) {}
  func offsets() -> (model: Double, presentation: Double) {
    guard let lab else { return (.nan, .nan) }
    return (Double(lab.content.bounds.origin.y), Double((lab.content.layer.presentation() ?? lab.content.layer).bounds.origin.y))
  }
  func resetToBottom() {
    guard let lab else { return }
    lab.content.layer.removeAnimation(forKey: "fling")
    lab.content.bounds.origin.y = lab.maxOffset
  }
  func setOffset(_ y: CGFloat) {
    lab?.content.layer.removeAnimation(forKey: "fling")
    lab?.content.bounds.origin.y = y
  }
  func teardown() {
    lab?.clip.removeGestureRecognizer(pan)
    lab?.clip.removeGestureRecognizer(down)
  }
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
    // rows move into the scroll view's content; `content` stays as their container at origin 0
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
}

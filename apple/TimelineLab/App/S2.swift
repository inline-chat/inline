import QuartzCore
import UIKit

/// Telegram-style window pan recogniser: stays `.possible`, never blocks other recognisers or touches.
final class WindowPan: UIGestureRecognizer {
  var began: ((CGPoint) -> Void)?
  var moved: ((CGPoint) -> Void)?
  var ended: ((CGPoint, CGPoint?) -> Void)?
  private var points: [(CGPoint, Double)] = []

  override func reset() { super.reset(); points.removeAll() }

  private func add(_ p: CGPoint) {
    points.append((p, CACurrentMediaTime()))
    if points.count > 8 { points.removeFirst() }
  }

  func velocity() -> CGPoint {
    let now = CACurrentMediaTime()
    let recent = points.filter { $0.1 >= now - 0.1 }
    guard let a = recent.first, let b = recent.last, b.1 - a.1 > 0.004 else { return .zero }
    return CGPoint(x: (b.0.x - a.0.x) / (b.1 - a.1), y: (b.0.y - a.0.y) / (b.1 - a.1))
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    if let t = touches.first { let p = t.location(in: view); add(p); began?(p) }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesMoved(touches, with: event)
    if let t = touches.first { let p = t.location(in: view); add(p); moved?(p) }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesEnded(touches, with: event)
    if let t = touches.first { let p = t.location(in: view); add(p); ended?(p, velocity()) }
    state = .failed
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesCancelled(touches, with: event)
    if let t = touches.first { ended?(t.location(in: view), nil) }
    state = .failed
  }
}

extension LabView {
  func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

  func installWindowPan(_ window: UIWindow) {
    guard windowPan == nil else { return }
    let p = WindowPan(target: nil, action: nil)
    p.cancelsTouchesInView = false
    p.delaysTouchesBegan = false
    p.delaysTouchesEnded = false
    p.delegate = self
    p.began = { [weak self] pt in self?.fingerBegan(pt) }
    p.moved = { [weak self] pt in self?.fingerMoved(pt) }
    p.ended = { [weak self] pt, v in self?.fingerEnded(pt, v) }
    window.addGestureRecognizer(p)
    windowPan = p
    LabHub.shared.onBackground = { [weak self] in self?.dumpKeyboardState(label: "background") }
    LabHub.shared.onForeground = { [weak self] in
      self?.dumpKeyboardState(label: "foreground")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.dumpKeyboardState(label: "foreground+1s") }
    }
  }

  func fingerBegan(_ p: CGPoint) {
    fingerY = Double(p.y)
    fingerEvents.append(String(format: "%.5f %d began %.1f %.1f", CACurrentMediaTime(), frameIndex, p.x, p.y))
    probe.mark("touch began y=\(p.y)", frame: frameIndex)
    if mode.hasPrefix("S2") { installKVOIfNeeded() }
    if mode == "S4" { s4Note("touch began \(fmt(p))") }
  }

  func fingerMoved(_ p: CGPoint) {
    fingerY = Double(p.y)
    fingerEvents.append(String(format: "%.5f %d moved %.1f %.1f", CACurrentMediaTime(), frameIndex, p.x, p.y))
    if mode == "S2priv" { privMove(p) }
  }

  func fingerEnded(_ p: CGPoint, _ v: CGPoint?) {
    fingerY = Double(p.y)
    fingerEvents.append(String(format: "%.5f %d ended %.1f %.1f v=%.1f", CACurrentMediaTime(), frameIndex, p.x, p.y, v?.y ?? .nan))
    probe.mark("touch ended y=\(p.y) vy=\(v?.y ?? .nan)", frame: frameIndex)
    if mode == "S2priv" { privEnd(p, v) }
    if mode == "S4" { s4Note("touch ended \(fmt(p))") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.saveSession() }
  }

  func saveSession() {
    probe.save()
    if GroundTruth.shared.running { GroundTruth.shared.save(name: mode) }
    Lab.write("\(mode)_kvo.txt", kvoEvents.joined(separator: "\n"))
    Lab.write("\(mode)_finger.txt", fingerEvents.joined(separator: "\n"))
    if mode == "S4" { s4Flush() }
    Lab.flushEvents()
  }

  // MARK: KVO (signal a)

  func installKVOIfNeeded() {
    guard accessory.window != nil else { return }
    let host = hostView()
    if let first = kvoHost, first === host, !kvoTargets.isEmpty { return }
    for (o, k) in kvoTargets { o.removeObserver(self, forKeyPath: k) }
    kvoTargets.removeAll()
    kvoHost = host
    var chain = [accessory] + KB.ancestors(accessory)
    if let host = KB.hostViaWindow(KB.keyboardWindow(scene: window?.windowScene)) { chain += [host] + KB.ancestors(host) }
    for v in chain {
      for k in ["center", "bounds", "frame"] { v.addObserver(self, forKeyPath: k, options: [.new], context: nil); kvoTargets.append((v, k)) }
      for k in ["position", "bounds", "transform", "sublayerTransform"] { v.layer.addObserver(self, forKeyPath: k, options: [.new], context: nil); kvoTargets.append((v.layer, k)) }
    }
    Lab.log("KVO installed on \(kvoTargets.count) (object,key) pairs: \(chain.map { Priv.cls($0) })")
  }

  nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    let desc = "\(String(describing: change?[.newKey] ?? "nil"))".replacingOccurrences(of: "\n", with: " ")
    let objCls = (object as AnyObject?).map { NSStringFromClass(type(of: $0)) } ?? "nil"
    let key = keyPath ?? ""
    MainActor.assumeIsolated {
      guard let host = hostView() else { return }
      let top = Double(KB.screenRect(host.layer, presentation: false).minY)
      kvoEvents.append(String(format: "%.5f %d %@.%@ top=%.2f inh=%.3f %@", CACurrentMediaTime(), frameIndex, objCls, key, top, UIView.inheritedAnimationDuration, desc))
      lastKVOTop = top
      if mode == "S2pub", driver == "kvo" || driver == "hybrid", !privActive {
        // Only follow the drag; animated changes (inherited duration > 0) are handled by the notification path.
        if UIView.inheritedAnimationDuration == 0 { applyKeyboardTop(screenY: top, source: "kvo") }
      }
    }
  }

  // MARK: private route

  var viewBottomScreen: CGFloat { convert(bounds, to: nil).maxY }

  func privMove(_ p: CGPoint) {
    guard textView.isFirstResponder, kbHeight > 0 else { return }
    let restComposerTop = viewBottomScreen - kbHeight - composerH
    let off = min(max(0, p.y - restComposerTop), kbHeight)
    if !privActive {
      guard off > 0 else { return }
      privActive = true
      probe.mark("priv begin", frame: frameIndex)
      dumpKeyboardState(label: "privBegin")
    }
    setPrivOffset(off)
  }

  func privEnd(_ p: CGPoint, _ v: CGPoint?) {
    guard privActive else { return }
    let vy = v?.y ?? 0
    if vy > 100 || dragOffset >= kbHeight - 0.5 {
      probe.mark("priv release dismiss vy=\(vy)", frame: frameIndex)
      setPrivOffset(kbHeight, spring: .system26(duration: 0.3832)) { [weak self] in self?.privFinishDismiss() }
    } else {
      probe.mark("priv release cancel vy=\(vy)", frame: frameIndex)
      setPrivOffset(0, spring: .system26(duration: 0.3832)) { [weak self] in
        guard let self else { return }
        self.privActive = false
        self.probe.mark("priv cancel done", frame: self.frameIndex)
        self.dumpKeyboardState(label: "afterCancel")
      }
    }
  }

  func setPrivOffset(_ off: CGFloat, spring: SpringParams? = nil, completion: (() -> Void)? = nil) {
    guard let host = hostView() else { return }
    let prev = dragOffset
    let oldC = composer.layer.position.y, oldClip = clip.layer.position.y
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let completion { CATransaction.setCompletionBlock(completion) }
    dragOffset = off
    applyLayout()
    shiftKeyboard(host, off)
    if let spring {
      for (l, old) in [(composer.layer, oldC), (clip.layer, oldClip)] where abs(old - l.position.y) > 0.01 {
        l.add(spring.make(keyPath: "position.y", from: old - l.position.y), forKey: nil)
      }
      if abs(prev - off) > 0.01 {
        let (target, keyPath, from) = shiftAnimationTarget(host, prev: prev, new: off)
        target.add(spring.make(keyPath: keyPath, from: from), forKey: nil)
      }
    }
    CATransaction.commit()
  }

  func shiftKeyboard(_ host: UIView, _ off: CGFloat) {
    switch kbMove {
    case "transform": host.layer.transform = CATransform3DMakeTranslation(0, off, 0)
    case "position":
      if privRestHostY.isNaN { privRestHostY = Double(host.layer.position.y) }
      host.layer.position.y = CGFloat(privRestHostY) + off
    case "container": if let c = host.superview { c.layer.bounds.origin.y = -off }
    case "window": host.window?.layer.sublayerTransform = CATransform3DMakeTranslation(0, off, 0)
    default: host.layer.bounds.origin.y = -off
    }
  }

  func shiftAnimationTarget(_ host: UIView, prev: CGFloat, new: CGFloat) -> (CALayer, String, CGFloat) {
    switch kbMove {
    case "transform": return (host.layer, "transform.translation.y", prev - new)
    case "position": return (host.layer, "position.y", prev - new)
    case "container": return (host.superview!.layer, "bounds.origin.y", new - prev)
    case "window": return (host.window!.layer, "sublayerTransform.translation.y", prev - new)
    default: return (host.layer, "bounds.origin.y", new - prev)
    }
  }

  func privFinishDismiss() {
    probe.mark("priv dismiss end (resign without animation)", frame: frameIndex)
    UIView.performWithoutAnimation {
      if Lab.arg("prewarm") == "swap" { kbClose() } else { _ = textView.resignFirstResponder() }
    }
    if let kw = hostView()?.window {
      func endAnims(_ v: UIView) { v.layer.removeAllAnimations(); v.subviews.forEach(endAnims) }
      kw.subviews.forEach(endAnims)
    }
    if let host = cachedHost {
      CATransaction.begin(); CATransaction.setDisableActions(true)
      shiftKeyboard(host, 0)
      CATransaction.commit()
    }
    privRestHostY = .nan
    kbHeight = 0; dragOffset = 0; privActive = false
    applyLayout()
    dumpKeyboardState(label: "afterDismiss")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.dumpKeyboardState(label: "afterDismiss+0.6s") }
  }

  /// Holds a fixed private offset without a finger (to test key hit-testing and backgrounding with an offset).
  func privHold(_ off: CGFloat) {
    guard kbHeight > 0 else { return }
    privActive = true
    setPrivOffset(min(off, kbHeight))
    dumpKeyboardState(label: "privHold \(off)")
  }

  func dumpKeyboardState(label: String) {
    let h = hostView()
    let l = h?.layer
    let k = keyboardTops()
    Lab.log("KBSTATE \(label) firstResponder=\(textView.isFirstResponder) kbHeight=\(kbHeight) dragOffset=\(dragOffset) privActive=\(privActive) host=\(Priv.cls(h)) hostWindow=\(Priv.cls(h?.window)) layer.bounds=\(fmt(l?.bounds ?? .zero)) position=\(fmt(l?.position ?? .zero)) transformId=\(l.map { CATransform3DIsIdentity($0.transform) } ?? true) containerBounds=\(fmt(h?.superview?.bounds ?? .zero)) windowSublayerTId=\(h?.window.map { CATransform3DIsIdentity($0.layer.sublayerTransform) } ?? true) kbTopP=\(f2(k.pres)) kbVisP=\(f2(k.vis)) composerBottom=\(f2(Double(KB.screenRect(composer.layer, presentation: true).maxY))) anims=\(l?.animationKeys() ?? [])")
    probe.save()
    Lab.flushEvents()
  }
}

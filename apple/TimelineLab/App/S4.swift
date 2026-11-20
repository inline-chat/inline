import QuartzCore
import UIKit

/// S4: back-swipe with the keyboard up (variants: resign | keep | translate) and rotation with the keyboard up.
extension LabView {
  func s4Note(_ s: String) {
    s4Events.append(String(format: "%.5f %d ", CACurrentMediaTime(), frameIndex) + s)
  }

  var navController: UINavigationController? {
    var r: UIResponder? = self
    while let cur = r { if let nc = cur as? UINavigationController { return nc }; r = cur.next }
    return nil
  }

  func setupS4() {
    guard !s4Installed else { return }
    s4Installed = true
    // Keyboard up from the start (S4 measures with the keyboard up).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self, Lab.arg("s4kb") != "0" else { return }
      self.textView.becomeFirstResponder()
      if Lab.arg("s4closed") == "1" {
        // inputView-swap "closed" state: still first responder, keyboard swapped out
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.kbClose(); self.s4Note("s4closed: keyboard swapped out (first responder kept)") }
      }
    }
    if let nc = navController {
      s4Note("nav=\(Priv.cls(nc)) edgePop=\(Priv.cls(nc.interactivePopGestureRecognizer))")
      nc.interactivePopGestureRecognizer?.addTarget(self, action: #selector(popGesture(_:)))
      let sel = NSSelectorFromString("interactiveContentPopGestureRecognizer")
      if nc.responds(to: sel), let g = nc.perform(sel)?.takeUnretainedValue() as? UIGestureRecognizer {
        g.addTarget(self, action: #selector(popGesture(_:)))
        s4Note("contentPop=\(Priv.cls(g))")
      } else {
        s4Note("contentPop=unavailable")
      }
    } else {
      s4Note("nav=nil")
    }
    LabHub.shared.willTransition = { [weak self] size, coordinator in self?.s4WillTransition(size, coordinator) }
  }

  @objc func popGesture(_ g: UIGestureRecognizer) {
    let name = g === navController?.interactivePopGestureRecognizer ? "edgePop" : "contentPop"
    s4Note("\(name) state=\(g.state.rawValue) loc=\(fmt(g.location(in: window))) firstResponder=\(textView.isFirstResponder)")
    guard g.state == .began else { if g.state == .ended || g.state == .cancelled { s4Flush() }; return }
    s4Transitioning = true
    switch s4Variant {
    case "resign":
      textView.resignFirstResponder()
      s4Note("resigned at gesture begin")
    case "translate":
      s4Translating = true
    case "keepignore":
      s4IgnoreKB = true
      s4Note("keepignore: ignoring keyboard notifications until the transition completes")
    default: break
    }
    if let tc = navController?.transitionCoordinator {
      s4Note("transitionCoordinator interactive=\(tc.isInteractive) dur=\(tc.transitionDuration) curve=\(tc.completionCurve.rawValue)")
      tc.notifyWhenInteractionChanges { [weak self] ctx in
        self?.s4Note("interactionChanged cancelled=\(ctx.isCancelled) percent=\(ctx.percentComplete) remaining=\(ctx.transitionDuration * (1 - ctx.percentComplete))")
      }
      tc.animate(alongsideTransition: nil) { [weak self] ctx in
        guard let self else { return }
        self.s4Note("transition completion cancelled=\(ctx.isCancelled)")
        self.s4Transitioning = false
        if self.s4IgnoreKB {
          if ctx.isCancelled {
            // UIKit re-shows the keyboard with 0-duration notifications around this point and the host is still
            // parked off screen: keep the composer where it is and stop ignoring shortly after.
            self.s4Note("keepignore: cancelled; composer untouched, ignoring for 0.3 s more")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
              self.s4IgnoreKB = false
              let k = self.keyboardTops()
              self.s4Note("keepignore: resumed; keyboard model top=\(f2(k.model)) kbHeight=\(self.kbHeight) firstResponder=\(self.textView.isFirstResponder)")
            }
          } else {
            self.s4IgnoreKB = false
            self.s4Note("keepignore: committed; firstResponder=\(self.textView.isFirstResponder)")
          }
        }
        if self.s4Translating { self.s4FinishTranslate(cancelled: ctx.isCancelled) }
        self.s4Flush()
      }
    } else {
      s4Note("transitionCoordinator=nil")
    }
  }

  /// Per-frame, from tick(): log geometry while transitioning; in "translate" make the keyboard follow the screen.
  func s4Tick() {
    guard s4Transitioning || s4Translating || s4Rotating else { return }
    let labP = KB.screenRect(layer, presentation: true)
    let host = hostView()
    let kbP = host.map { KB.screenRect($0.layer, presentation: true) } ?? .null
    if s4Translating, let kw = host?.window {
      CATransaction.begin(); CATransaction.setDisableActions(true)
      kw.layer.sublayerTransform = CATransform3DMakeTranslation(labP.minX, 0, 0)
      CATransaction.commit()
    }
    s4Note("tick labP=\(fmt(labP)) labBounds=\(fmt(bounds)) kbP=\(fmt(kbP)) composerP=\(fmt(KB.screenRect(composer.layer, presentation: true))) safe=\(safeAreaInsets.bottom) fr=\(textView.isFirstResponder)")
  }

  func s4FinishTranslate(cancelled: Bool) {
    s4Translating = false
    let kw = hostView()?.window
    if cancelled {
      kw?.layer.sublayerTransform = CATransform3DIdentity
      s4Note("translate: cancelled → keyboard window transform reset")
    } else {
      UIView.performWithoutAnimation { _ = textView.resignFirstResponder() }
      if let kw {
        func endAnims(_ v: UIView) { v.layer.removeAllAnimations(); v.subviews.forEach(endAnims) }
        kw.subviews.forEach(endAnims)
        kw.layer.sublayerTransform = CATransform3DIdentity
      }
      s4Note("translate: committed → resigned without animation, transform reset")
    }
  }

  func s4LayoutPass() {
    s4Note("layoutSubviews pass=\(layoutPasses) bounds=\(fmt(bounds)) safe=\(safeAreaInsets) kbHeight=\(kbHeight) frozen=\(freezeKeyboardLayout) guideTop=\(lastGuideTop) window=\(window.map { fmt($0.bounds) } ?? "nil")")
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    if mode == "S4" { s4Note("safeAreaInsetsDidChange \(safeAreaInsets)") }
  }

  // MARK: rotation

  func s4WillTransition(_ size: CGSize, _ coordinator: any UIViewControllerTransitionCoordinator) {
    s4Note("viewWillTransition to=\(size) dur=\(coordinator.transitionDuration) curve=\(coordinator.completionCurve.rawValue) bounds=\(fmt(bounds)) kbHeight=\(kbHeight)")
    s4Rotating = true
    let recipe = Lab.arg("rotrecipe") == "1"
    if recipe { freezeKeyboardLayout = true; s4PendingKB = nil }
    coordinator.animate(alongsideTransition: { [weak self] ctx in
      guard let self else { return }
      self.s4Note("alongside begin bounds=\(fmt(self.bounds)) pendingKB=\(String(describing: self.s4PendingKB)) inheritedDur=\(UIView.inheritedAnimationDuration)")
      if recipe {
        if let kb = self.s4PendingKB { self.kbHeight = kb }
        self.applyLayout()
        self.s4Note("alongside applied one layout kbHeight=\(self.kbHeight) (pendingKnown=\(self.s4PendingKB != nil))")
      }
    }, completion: { [weak self] ctx in
      guard let self else { return }
      self.s4Note("rotation completion bounds=\(fmt(self.bounds)) pendingKB=\(String(describing: self.s4PendingKB))")
      if recipe {
        self.freezeKeyboardLayout = false
        if let kb = self.s4PendingKB, abs(kb - self.kbHeight) > 0.5 {
          self.s4Note("recipe: keyboard height arrived after alongside → second pass \(self.kbHeight)→\(kb)")
          self.animateKeyboard(to: kb, spring: .system26(duration: 0.3833))
        }
        self.s4PendingKB = nil
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.s4Rotating = false; self.s4Flush() }
    })
  }

  func s4Flush() {
    Lab.write("S4_events_\(s4InstanceID).txt", s4Events.joined(separator: "\n"))
    Lab.flushEvents()
  }
}

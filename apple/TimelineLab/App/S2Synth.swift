import QuartzCore
import UIKit

/// In-app synthetic finger for the private interactive-dismissal route. It feeds the lab's own window-pan handlers
/// (fingerBegan/fingerMoved/fingerEnded → privMove/privEnd) from a scripted path, sampled on the display link.
/// It BYPASSES the real touch pipeline (no UITouch, no hit-testing, no gesture-recogniser arbitration, no touch
/// coalescing); what it exercises is our keyboard-move code under exactly-timed input.
@MainActor
final class SynthFinger {
  struct Leg { let y: CGFloat; let dur: Double }
  let name: String
  let x: CGFloat = 250
  let y0: CGFloat
  let legs: [Leg]
  let start: CFTimeInterval
  var began = false
  var done = false
  var onDone: (() -> Void)?
  var samples: [(Double, CGFloat)] = []

  init(name: String, from y0: CGFloat, legs: [Leg], start: CFTimeInterval) {
    self.name = name; self.y0 = y0; self.legs = legs; self.start = start
  }

  var total: Double { legs.map(\.dur).reduce(0, +) }

  func y(at t: Double) -> CGFloat {
    var cur = y0, acc = 0.0
    for l in legs {
      if t <= acc + l.dur { let f = l.dur > 0 ? (t - acc) / l.dur : 1; return cur + (l.y - cur) * CGFloat(f) }
      acc += l.dur; cur = l.y
    }
    return cur
  }

  func tick(_ lab: LabView) {
    guard !done else { return }
    let now = CACurrentMediaTime()
    guard now >= start else { return }
    let t = now - start
    let p = CGPoint(x: x, y: y(at: min(t, total)))
    samples.append((now, p.y))
    if !began {
      began = true
      lab.probe.mark("synth \(name) begin", frame: lab.frameIndex)
      lab.fingerBegan(p)
      return
    }
    if t < total {
      lab.fingerMoved(p)
    } else {
      // release velocity: slope over the last 50 ms of the scripted path (pt/s, +down)
      let tEnd = total
      let v = (y(at: tEnd) - y(at: max(0, tEnd - 0.05))) / 0.05
      lab.fingerMoved(p)
      lab.fingerEnded(p, CGPoint(x: 0, y: v))
      lab.probe.mark(String(format: "synth %@ end y=%.1f vy=%.1f", name, Double(p.y), Double(v)), frame: lab.frameIndex)
      done = true
      onDone?()
    }
  }
}

extension LabView {
  func runSynth(_ name: String, from y0: CGFloat, _ legs: [SynthFinger.Leg]) async {
    if !kbIsOpen { kbOpen(); await Lab.sleep(1.2) }
    let f = SynthFinger(name: name, from: y0, legs: legs, start: CACurrentMediaTime() + 0.05)
    synth = f
    while !f.done { await Lab.sleep(0.05) }
    await Lab.sleep(1.2)
    dumpKeyboardState(label: "after synth \(name)")
    synth = nil
  }

  /// Scripted private-route scenarios (S2priv, `-synth 1`; works with any -kbmove, intended for transform).
  func runSynthFinger() async {
    Lab.log("synth start kbmove=\(kbMove) prewarm=\(Lab.arg("prewarm") ?? "-")")
    await Lab.sleep(0.5)
    kbOpen(); await Lab.sleep(1.5)
    typealias L = SynthFinger.Leg
    // y values are relative to the composer's resting top (357 on the iPhone SE), so the scripts mean the same on
    // other screen sizes.
    let top = viewBottomScreen - kbHeight - composerH
    func Y(_ d: CGFloat) -> CGFloat { top + d }
    Lab.log("synth composer rest top=\(top)")
    // 0) held offset for backgrounding (the UI test presses home around t≈7 s after launch)
    await runSynth("hold-bg", from: Y(-177), [L(y: Y(163), dur: 0.4), L(y: Y(163), dur: 9.0), L(y: Y(-157), dur: 0.3)])
    // 1) cancel by dragging back up above the keyboard
    await runSynth("back-up-above", from: Y(-177), [L(y: Y(183), dur: 0.35), L(y: Y(183), dur: 0.15), L(y: Y(-107), dur: 0.35)])
    // 2) drag back up partially, release moving up
    await runSynth("back-up-partial", from: Y(-177), [L(y: Y(243), dur: 0.4), L(y: Y(93), dur: 0.25)])
    // 3) still release at several depths
    for d in [73.0, 113.0, 183.0] {
      await runSynth("still+\(Int(d))", from: Y(-177), [L(y: Y(CGFloat(d)), dur: 0.35), L(y: Y(CGFloat(d)), dur: 0.4)])
    }
    // 4) slow downward releases: ~80 pt/s (below the 100 threshold) and ~300 pt/s
    await runSynth("slow80", from: Y(-177), [L(y: Y(163), dur: 0.35), L(y: Y(183), dur: 0.25)])
    await runSynth("slow300", from: Y(-177), [L(y: Y(123), dur: 0.35), L(y: Y(183), dur: 0.2)])
    // 5) flicks
    await runSynth("flick1200", from: Y(-177), [L(y: Y(293), dur: 0.39)])
    await runSynth("flick600", from: Y(-177), [L(y: Y(243), dur: 0.7)])
    Lab.log("synth done")
    probe.save()
    Lab.write("S2synth.done", "done")
    Lab.flushEvents()
  }

  // MARK: inputView-swap side effects (S1, -prewarm swap -swapfx 1)

  func caretState() -> String {
    var found: [String] = []
    func walk(_ v: UIView, _ d: Int) {
      let c = Priv.cls(v)
      if c.contains("Cursor") || c.contains("Caret") || c.contains("Selection") || c.contains("TextRange") {
        let p = v.layer.presentation()
        found.append("\(c) hidden=\(v.isHidden) alpha=\(v.alpha) opacity=\(v.layer.opacity) presOpacity=\(p.map { "\($0.opacity)" } ?? "-") frame=\(fmt(v.frame)) anims=\(v.layer.animationKeys() ?? [])")
      }
      if d < 8 { v.subviews.forEach { walk($0, d + 1) } }
    }
    walk(textView, 0)
    return found.isEmpty ? "no caret-like views" : found.joined(separator: " | ")
  }

  func swapState(_ label: String) {
    let k = keyboardTops()
    let kw = KB.keyboardWindow(scene: window?.windowScene)
    Lab.log("SWAPFX \(label) firstResponder=\(textView.isFirstResponder) inputView=\(Priv.cls(textView.inputView)) selected=\(textView.selectedRange) kbTopP=\(f2(k.pres)) kbTopM=\(f2(k.model)) guideTop=\(f2(lastGuideTop)) keyboardWindow=\(Priv.cls(kw)) hidden=\(kw?.isHidden ?? true) accessory.window=\(Priv.cls(accessory.window)) accessory.superview=\(Priv.cls(accessory.superview)) accFrame=\(fmt(accessory.superview?.frame ?? .zero)) itemTop=\(f2(itemTop(false))) kbHeight=\(kbHeight) caret: \(caretState())")
  }

  func runSwapFX() async {
    Lab.log("swapfx start")
    await Lab.sleep(Double(Lab.arg("s1delay") ?? "0") ?? 0)
    textView.text = "hello"
    textView.becomeFirstResponder(); await Lab.sleep(1.2)
    swapState("open")
    for cycle in 0..<3 {
      kbClose(); await Lab.sleep(0.6)
      for i in 0..<4 { swapState("closed c\(cycle) s\(i)"); await Lab.sleep(0.3) }
      kbOpen(); await Lab.sleep(0.8)
      swapState("reopened c\(cycle)")
    }
    // typing while closed: insertText from software is possible; a hardware keyboard cannot be tested here
    kbClose(); await Lab.sleep(0.6)
    textView.insertText(" x")
    swapState("closed after insertText (text=\(textView.text ?? ""))")
    Lab.write("swapfx.done", "done")
    Lab.flushEvents()
  }
}

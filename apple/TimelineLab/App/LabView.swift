import QuartzCore
import UIKit

/// The lab screen: manually laid-out bottom-aligned rows in `content`, a composer bar, and a per-frame probe.
/// No UICollectionView / UITableView.
final class LabView: UIView, UITextViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  let mode: String
  let clip = UIView()
  let content = UIView()
  var rows: [UIView] = []
  var contentHeight: CGFloat = 0
  let composer = UIView()
  let textView = UITextView()
  let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  let guideProbe = UIView()
  var counterBits: [CALayer] = []
  let composerH: CGFloat = 50

  /// Keyboard height applied to layout (our coordinates). `dragOffset` is the private-route interactive offset.
  var kbHeight: CGFloat = 0
  var dragOffset: CGFloat = 0
  var freezeKeyboardLayout = false

  var link: CADisplayLink?
  var frameIndex = 0
  var probe = Probe()

  // S1
  var variant = Lab.arg("variant") ?? "A"
  var dumpNextNotification = true
  var systemSpring: SpringParams?
  // S2
  var driver = Lab.arg("driver") ?? "kvo"
  var kbMove = Lab.arg("kbmove") ?? "bounds"
  let dragScroll = UIScrollView()
  var kvoTargets: [(NSObject, String)] = []
  weak var kvoHost: UIView?
  var kvoEvents: [String] = []
  var lastKVOTop: Double = .nan
  var lastScrollTop: Double = .nan
  var lastGuideTop: Double = .nan
  var fingerY: Double = .nan
  var fingerEvents: [String] = []
  var notifCount = 0
  var windowPan: WindowPan?
  var privActive = false
  var privRestComposerTop: CGFloat = 0
  var privRestHostY: Double = .nan
  var privHeldOnce = false
  // S3
  var engine: ScrollEngine?
  var engineChip = UISegmentedControl(items: ["U", "C", "R"])
  // S4
  var s4Variant = Lab.arg("s4") ?? "resign"
  var s4Events: [String] = []
  var s4Installed = false
  var s4Transitioning = false
  var s4Translating = false
  var s4Rotating = false
  let s4InstanceID = Int(CACurrentMediaTime() * 1000) % 100000
  var s3ResetWork: DispatchWorkItem?
  var s3Buttons: [UIButton] = []
  var lastVelocityEstimates: [String: Double] = [:]
  var s3FlingCPU0: Double = 0
  var s3FlingWall0: Double = 0
  var s3TickWork: Double = 0
  var s3TickCount = 0
  var s3PrependArmed = false
  var s3PrependArmedOverride = false
  var virtualList: VirtualList?
  var s4IgnoreKB = false
  var synth: SynthFinger?
  var popObserver: NSObjectProtocol?
  var layoutPasses = 0

  init(mode: String) {
    self.mode = mode
    super.init(frame: .zero)
    backgroundColor = UIColor(red: 0, green: 1, blue: 0, alpha: 1) // green: visible only in gaps under the composer
    clipsToBounds = false
    clip.clipsToBounds = true
    clip.backgroundColor = UIColor(white: 0.97, alpha: 1)
    addSubview(clip)
    clip.addSubview(content)
    buildRows()
    if mode == "S3L" { setupVirtualList() }

    if mode.hasPrefix("S2") || mode == "S1" || mode == "S4" {
      dragScroll.backgroundColor = .clear
      dragScroll.alwaysBounceVertical = true
      dragScroll.showsVerticalScrollIndicator = false
      dragScroll.delegate = self
      dragScroll.keyboardDismissMode = mode == "S2pub" ? .interactive : .none
      dragScroll.contentInsetAdjustmentBehavior = .never
      addSubview(dragScroll)
    }

    composer.backgroundColor = UIColor(red: 1, green: 0, blue: 1, alpha: 1) // magenta: pixel-detectable
    addSubview(composer)
    textView.font = .systemFont(ofSize: 16)
    textView.backgroundColor = .white
    textView.layer.cornerRadius = 8
    textView.autocorrectionType = .yes
    textView.accessibilityIdentifier = "composerText"
    accessory.backgroundColor = .clear
    textView.inputAccessoryView = accessory
    if Lab.arg("composerext") == "1" {
      let skirt = UIView(frame: CGRect(x: 0, y: composerH, width: 2000, height: 600))
      skirt.backgroundColor = composer.backgroundColor
      composer.addSubview(skirt)
    }
    textView.delegate = self
    composer.addSubview(textView)

    guideProbe.isUserInteractionEnabled = false
    guideProbe.translatesAutoresizingMaskIntoConstraints = false
    addSubview(guideProbe)
    NSLayoutConstraint.activate([
      guideProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
      guideProbe.widthAnchor.constraint(equalToConstant: 1),
      guideProbe.heightAnchor.constraint(equalToConstant: 1),
      guideProbe.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
    ])

    for i in 0..<12 {
      let l = CALayer()
      l.frame = CGRect(x: 4 + CGFloat(i) * 14, y: 2, width: 14, height: 12)
      l.backgroundColor = UIColor.black.cgColor
      l.zPosition = 1000
      layer.addSublayer(l)
      counterBits.append(l)
      _ = i
    }

    for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                 UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                 UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(keyboardNotification(_:)), name: name, object: nil)
    }
    setupS3()
  }

  required init?(coder: NSCoder) { fatalError() }

  // MARK: rows

  func buildRows() {
    var seed: UInt64 = 0x1234_5678
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
    var y: CGFloat = 0
    for i in 0..<60 {
      let h = CGFloat(44 + Int(rnd() * 140))
      // Hues avoid magenta (~0.83) and green (~0.33) so the pixel detector never confuses rows with the composer/gap.
      let hueBands: [(Double, Double)] = [(0.0, 0.22), (0.48, 0.72)]
      let band = hueBands[i % 2]
      let hue = band.0 + rnd() * (band.1 - band.0)
      let v = UIView(frame: CGRect(x: 8, y: y, width: 0, height: h - 6))
      v.backgroundColor = UIColor(hue: hue, saturation: 0.35, brightness: 0.93, alpha: 1)
      v.layer.cornerRadius = 10
      let label = UILabel(frame: CGRect(x: 10, y: 6, width: 200, height: 18))
      label.text = "row \(i)  h=\(Int(h))"
      label.font = .systemFont(ofSize: 13)
      label.textColor = .darkGray
      v.addSubview(label)
      content.addSubview(v)
      rows.append(v)
      y += h
    }
    contentHeight = y
  }

  // MARK: layout

  var effectiveKB: CGFloat { max(0, kbHeight - dragOffset) }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutPasses += 1
    if mode == "S4" { s4LayoutPass() }
    if !lastGuideTopValid() { /* first pass */ }
    // signal (d): keyboardLayoutGuide read in layoutSubviews
    let g = guideProbe.convert(guideProbe.bounds, to: nil).maxY
    if g.isFinite { lastGuideTop = Double(g) }
    if mode == "S2pub", driver == "guide", lastGuideTop.isFinite { applyKeyboardTop(screenY: lastGuideTop, source: "guide") }
    layoutStatic()
  }

  func lastGuideTopValid() -> Bool { lastGuideTop.isFinite }

  /// Lays out everything that depends only on bounds (rows, widths); then the keyboard-dependent frames.
  func layoutStatic() {
    let w = bounds.width
    for r in rows { r.frame.size.width = w - 16 }
    if engine == nil {
      let clipH = bounds.height - composerH
      content.frame = CGRect(x: 0, y: 0, width: w, height: clipH)
      content.bounds.origin.y = contentHeight - clipH
    } else {
      engine?.layoutChanged()
    }
    dragScroll.frame = CGRect(x: 0, y: 0, width: w, height: max(0, bounds.height - composerH - effectiveKB))
    dragScroll.contentSize = CGSize(width: w, height: dragScroll.bounds.height + 1)
    if !freezeKeyboardLayout { applyLayout() }
    engineChip.frame = CGRect(x: w - 120, y: 18, width: 110, height: 30)
    for b in s3Buttons { bringSubviewToFront(b) }
    bringSubviewToFront(engineChip)
  }

  /// Keyboard-dependent frames. Composer bottom == keyboard top; content bottom == composer top.
  func applyLayout() {
    let w = bounds.width, h = bounds.height
    let kb = effectiveKB
    composer.frame = CGRect(x: 0, y: h - composerH - kb, width: w, height: composerH)
    textView.frame = CGRect(x: 10, y: 7, width: min(170, w * 0.45), height: composerH - 14)
    let clipH = h - composerH
    let cf = CGRect(x: 0, y: -kb, width: w, height: clipH)
    if clip.frame != cf { clip.frame = cf }
  }

  /// Moves the layout to a keyboard top given in screen coordinates (S2 drivers).
  func applyKeyboardTop(screenY: Double, source: String) {
    let viewBottom = convert(bounds, to: nil).maxY
    let kb = max(0, viewBottom - CGFloat(screenY))
    if abs(kb - kbHeight) < 0.01 { return }
    kbHeight = kb
    CATransaction.begin(); CATransaction.setDisableActions(true)
    applyLayout()
    CATransaction.commit()
  }

  // MARK: lifecycle

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard let window else { link?.invalidate(); link = nil; return }
    if link == nil {
      let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
      l.add(to: .main, forMode: .common)
      link = l
    }
    Lab.log("lab didMoveToWindow mode=\(mode) window=\(Priv.cls(window)) frame=\(fmt(window.frame)) screen=\(Unmanaged.passUnretained(window.screen).toOpaque())")
    if mode.hasPrefix("S2") || mode.hasPrefix("S3") || mode == "S4" { installWindowPan(window) }
    if mode == "S4" { setupS4() }
    if Lab.autorun {
      Task { @MainActor in
        await Lab.sleep(1.0)
        switch mode {
        case "S1" where Lab.arg("swapfx") == "1": await runSwapFX()
        case "S1": await runS1()
        case "S2priv" where Lab.arg("synth") == "1": await runSynthFinger()
        case "S3L" where Lab.arg("autofling") == "1": await runAutoFling()
        case "S3U", "S3C", "S3R": break
        default: break
        }
      }
    }
    if mode.hasPrefix("S2") || mode.hasPrefix("S3") || mode == "S4" {
      probe.start(name: "\(mode)_session", columns: sessionColumns)
      Task { @MainActor in await Lab.sleep(0.8); _ = await self.startGT() }
    }
  }

  func gtGeometry() -> GTGeometry {
    let o = convert(CGPoint.zero, to: nil)
    var g = GTGeometry()
    g.screenW = Double(window?.bounds.width ?? 375)
    g.screenH = Double(window?.bounds.height ?? 667)
    g.counterY = Double(o.y + 8)
    g.counterX0 = Double(o.x + 11)
    g.scanX = Double(o.x + bounds.width - 60)
    g.scanFromY = Double(o.y + 20)
    g.composerH = Double(composerH)
    return g
  }

  func startGT() async -> Bool {
    guard Lab.arg("gt") == "1" else { return false }
    GroundTruth.shared.setGeometry(gtGeometry())
    let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      GroundTruth.shared.start { c.resume(returning: $0) }
    }
    Lab.log("GT started=\(ok) geometry=\(gtGeometry())")
    return ok
  }

  // MARK: keyboard view access

  var cachedHost: UIView?
  /// The keyboard window and host are rebuilt on every show, so always resolve through the scene's current
  /// keyboard window (cheap: two levels of subviews).
  func hostView() -> UIView? {
    let current = KB.hostViaWindow(KB.keyboardWindow(scene: window?.windowScene)) ?? KB.hostViaAccessory(accessory)
    if current !== cachedHost { cachedHost = current }
    return cachedHost
  }

  /// Keyboard top in screen coordinates: host view's top (includes our 1pt accessory), and the visible top
  /// (min over the host's sublayers, which reflects a bounds-origin shift of the host).
  func keyboardTops() -> (pres: Double, model: Double, vis: Double) {
    guard let host = hostView(), host.window != nil else { return (.nan, .nan, .nan) }
    // + accessory height: our 1 pt accessory is transparent, the visible keyboard starts below it.
    let acc = accessory.bounds.height
    let p = KB.screenRect(host.layer, presentation: true).minY + acc
    let m = KB.screenRect(host.layer, presentation: false).minY + acc
    var vis = CGFloat.infinity
    for s in host.layer.sublayers ?? [] where !s.isHidden && s.bounds.height > 2 {
      vis = min(vis, KB.screenRect(s, presentation: true).minY)
    }
    return (Double(p), Double(m), vis.isFinite ? Double(vis) : .nan)
  }

  /// Top of the accessory's container (UIKeyboardItemContainerView in UITextEffectsWindow), screen coords.
  func itemTop(_ pres: Bool) -> Double {
    guard let c = accessory.superview, c.window != nil else { return .nan }
    return Double(KB.screenRect(c.layer, presentation: pres).minY)
  }

  // MARK: probe

  let sessionColumns = ["frame", "ts", "target", "now", "kbTopP", "kbTopM", "kbVisP", "compBotP", "compBotM", "rowBotP",
                        "kvoTop", "scrollTop", "guideTop", "finger", "notifs", "dragOffset", "contentY", "contentYP", "itemTopP", "itemTopM"]

  @objc func tick(_ l: CADisplayLink) {
    frameIndex += 1
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for (i, b) in counterBits.enumerated() {
      b.backgroundColor = ((frameIndex >> (11 - i)) & 1) == 1 ? UIColor.white.cgColor : UIColor.black.cgColor
    }
    CATransaction.commit()
    if mode == "S2pub", driver == "link" {
      let k = keyboardTops()
      if k.pres.isFinite { applyKeyboardTop(screenY: k.pres, source: "link") }
    }
    engine?.tick(l)
    if mode.hasPrefix("S3") { s3Tick(l) }
    if mode == "S4" { s4Tick() }
    synth?.tick(self)
    guard probe.recording else { return }
    let k = keyboardTops()
    let cP = KB.screenRect(composer.layer, presentation: true).maxY
    let cM = KB.screenRect(composer.layer, presentation: false).maxY
    let rP = rows.last.map { KB.screenRect($0.layer, presentation: true).maxY } ?? .nan
    var cy = Double(content.bounds.origin.y)
    var cyP = Double((content.layer.presentation() ?? content.layer).bounds.origin.y)
    if let e = engine { (cy, cyP) = e.offsets() }
    probe.add([Double(frameIndex), l.timestamp, l.targetTimestamp, CACurrentMediaTime(), k.pres, k.model, k.vis,
               Double(cP), Double(cM), Double(rP), lastKVOTop, lastScrollTop, lastGuideTop, fingerY, Double(notifCount),
               Double(dragOffset), cy, cyP, itemTop(true), itemTop(false)])
  }

  // MARK: keyboard notifications

  @objc func keyboardNotification(_ n: Notification) {
    notifCount += 1
    let info = n.userInfo ?? [:]
    let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
    let begin = (info[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect) ?? .zero
    let dur = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
    let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 0
    let local = (info[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? true
    let name = n.name.rawValue.replacingOccurrences(of: "UIKeyboard", with: "").replacingOccurrences(of: "Notification", with: "")
    let k = keyboardTops()
    Lab.log("KBN \(name) frame=\(frameIndex) begin=\(fmt(begin)) end=\(fmt(end)) dur=\(dur) curve=\(curve) local=\(local) inheritedDur=\(UIView.inheritedAnimationDuration) animsEnabled=\(UIView.areAnimationsEnabled) hostTopP=\(f2(k.pres)) hostTopM=\(f2(k.model)) obj=\(Priv.cls(n.object as AnyObject?)) finger=\(f2(fingerY)) bounds=\(fmt(bounds))")
    probe.mark("\(name) dur=\(dur) curve=\(curve) endY=\(end.minY) inh=\(UIView.inheritedAnimationDuration)", frame: frameIndex)
    if mode == "S4" { s4Note("KBN \(name) begin=\(fmt(begin)) end=\(fmt(end)) dur=\(dur) curve=\(curve) inh=\(UIView.inheritedAnimationDuration)") }
    if n.name == UIResponder.keyboardDidShowNotification, mode == "S2priv", let h = Lab.arg("privhold"), let off = Double(h), !privHeldOnce {
      privHeldOnce = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.privHold(CGFloat(off)) }
    }
    guard n.name == UIResponder.keyboardWillChangeFrameNotification else { return }

    if mode.hasPrefix("S2") && !dumpNextNotification {
      dumpKeyboardAnimations(label: "s2-atNotification")
      DispatchQueue.main.async { self.dumpKeyboardAnimations(label: "s2-nextTurn") }
    }
    if dumpNextNotification {
      dumpKeyboardAnimations(label: "atNotification")
      DispatchQueue.main.async { self.dumpKeyboardAnimations(label: "nextTurn") }
      dumpNextNotification = false
    }
    captureSystemSpring()
    DispatchQueue.main.async { self.captureSystemSpring() }

    let target = keyboardHeight(forEndFrame: end, screen: n.object as? UIScreen)
    if s4IgnoreKB { s4Note("keepignore: ignored \(name) target=\(target)"); return }
    if freezeKeyboardLayout { s4PendingKB = target; return }
    if privActive { return }
    switch mode {
    case "S1": s1Apply(target: target, dur: dur, curve: curve)
    case "S2pub" where driver == "link" || driver == "guide":
      // These drivers own every keyboard change (display-link presentation / layout-guide passes).
      break
    case "S2pub" where driver == "hybrid":
      copyHostAnimation(target: target)
    case "S2pub", "S2priv":
      // Opening / non-interactive changes: spring (variant A). During an interactive system drag the signal drivers own it.
      s1Apply(target: target, dur: dur, curve: curve, forceVariant: "A")
    default:
      s1Apply(target: target, dur: dur, curve: curve, forceVariant: "A")
    }
  }

  var s4PendingKB: CGFloat?

  func keyboardHeight(forEndFrame end: CGRect, screen: UIScreen?) -> CGFloat {
    let space: UICoordinateSpace = screen?.coordinateSpace ?? window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
    let r = convert(end, from: space)
    if end.minY >= (screen?.bounds.height ?? UIScreen.main.bounds.height) - 1 { return 0 }
    return max(0, bounds.maxY - r.minY - accessory.bounds.height)
  }

  func dumpKeyboardAnimations(label: String) {
    var out: [String] = ["=== keyboard animations \(label) frame=\(frameIndex) t=\(CACurrentMediaTime())"]
    guard let host = hostView() else { Lab.log("dump \(label): no host"); return }
    var a: CALayer? = host.layer.superlayer
    var depth = -1
    while let l = a {
      for key in l.animationKeys() ?? [] { if let an = l.animation(forKey: key) { out.append("ancestor\(depth) layer=\(Priv.cls(l)) key=\(key) \(KB.describe(an, on: l))") } }
      a = l.superlayer; depth -= 1
    }
    KB.dumpAnimations(host.layer, label: "host+", into: &out)
    // our own layers too (variant D: inherited animations)
    for (n, l) in [("composer", composer.layer), ("clip", clip.layer)] {
      for key in l.animationKeys() ?? [] { if let an = l.animation(forKey: key) { out.append("ours.\(n) key=\(key) \(KB.describe(an, on: l))") } }
    }
    Lab.log(out.joined(separator: "\n"))
  }

  func captureSystemSpring() {
    guard let host = hostView() else { return }
    var layers: [CALayer] = [host.layer]
    var a = host.layer.superlayer
    while let l = a { layers.append(l); a = l.superlayer }
    for l in layers {
      for key in l.animationKeys() ?? [] {
        if let sp = l.animation(forKey: key) as? CASpringAnimation {
          let p = SpringParams(mass: sp.mass, stiffness: sp.stiffness, damping: sp.damping, duration: sp.duration, v0: sp.initialVelocity, tf: sp.timingFunction)
          if systemSpring == nil { Lab.log("captured system spring \(p) from \(Priv.cls(l)) key=\(key)") }
          systemSpring = p
          return
        }
      }
    }
  }

  /// Hybrid driver: at a keyboard change, apply the host layer's own (newest) position animation to our layers.
  func copyHostAnimation(target: CGFloat) {
    let oldC = composer.layer.position.y, oldClip = clip.layer.position.y
    kbHeight = target
    CATransaction.begin(); CATransaction.setDisableActions(true)
    applyLayout()
    CATransaction.commit()
    guard let host = hostView(), let key = (host.layer.animationKeys() ?? []).last(where: { $0.hasPrefix("position") }),
          let sys = host.layer.animation(forKey: key) as? CABasicAnimation else {
      Lab.log("hybrid: no host animation; snapping")
      return
    }
    for (l, old) in [(composer.layer, oldC), (clip.layer, oldClip)] {
      let d = old - l.position.y
      if abs(d) < 0.01 { continue }
      guard let a = sys.copy() as? CABasicAnimation else { continue }
      a.keyPath = "position.y"
      a.fromValue = d; a.toValue = 0; a.byValue = nil
      a.isAdditive = true
      l.add(a, forKey: nil)
    }
    Lab.log("hybrid: copied \(KB.describe(sys, on: host.layer))")
  }

  // MARK: S1 variants

  func s1Apply(target: CGFloat, dur: Double, curve: Int, forceVariant: String? = nil) {
    let v = forceVariant ?? variant
    let spring = SpringParams.system26(duration: dur > 0 ? dur : 0.3832)
    switch v {
    case "A": animateKeyboard(to: target, spring: spring)
    case "A2": animateKeyboard(to: target, spring: systemSpring ?? spring)
    case "B":
      UIView.animate(withDuration: dur, delay: 0, options: [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState]) {
        self.kbHeight = target; self.applyLayout()
      }
    case "C": DispatchQueue.main.async { self.animateKeyboard(to: target, spring: spring) }
    case "D": kbHeight = target; applyLayout() // inherit whatever animation context UIKit posts the notification in
    default: animateKeyboard(to: target, spring: spring)
    }
  }

  /// Final frames now; explicit additive springs with unset beginTime.
  func animateKeyboard(to target: CGFloat, spring: SpringParams) {
    let oldC = composer.layer.position.y, oldClip = clip.layer.position.y
    kbHeight = target
    CATransaction.begin(); CATransaction.setDisableActions(true)
    applyLayout()
    CATransaction.commit()
    for (l, old) in [(composer.layer, oldC), (clip.layer, oldClip)] {
      let d = old - l.position.y
      if abs(d) < 0.01 { continue }
      l.add(spring.make(keyPath: "position.y", from: d), forKey: nil)
    }
  }

  // MARK: S1 runner

  func runS1() async {
    let variants = (Lab.arg("variants") ?? "A,A2,B,C,D").split(separator: ",").map(String.init)
    let reps = Int(Lab.arg("reps") ?? "10") ?? 10
    Lab.log("S1 start variants=\(variants) reps=\(reps) \(KB.describeOOP())")
    let gt = await startGT()
    await Lab.sleep(1.0)
    // let the frame counter and the video sync settle before the first open after launch
    await Lab.sleep(Double(Lab.arg("s1delay") ?? "0") ?? 0)
    // Warm-up: create the keyboard, dump the hierarchy.
    Lab.log("HWKB before: \(HWKB.describe())")
    Lab.log("UIKeyboardImpl hw methods: \(HWKB.methods("UIKeyboardImpl", filter: "hardware"))")
    Lab.log("UIKeyboard hw methods: \(HWKB.methods("UIKeyboard", filter: "hardware"))")
    variant = variants[0]
    probe.start(name: "S1/\(variants[0])_first_0", columns: sessionColumns)
    probe.mark("trial first open after launch", frame: frameIndex)
    await Lab.sleep(0.1)
    textView.becomeFirstResponder()
    await Lab.sleep(1.0)
    probe.stop()
    Lab.log("HWKB open: \(HWKB.describe())")
    if Lab.arg("forcesoft") == "1" { HWKB.forceSoftware(); await Lab.sleep(0.6); Lab.log("HWKB after force: \(HWKB.describe()) hostTop=\(keyboardTops().model)") }
    await Lab.sleep(1.2)
    GroundTruth.shared.requestFrames("warmopen", count: 2)
    dumpHierarchy(label: "open")
    kbClose()
    await Lab.sleep(1.0)
    dumpHierarchy(label: "closed")
    for v in variants {
      variant = v
      for scenario in (Lab.arg("s1scen") ?? "open,close,reverse").split(separator: ",").map(String.init) {
        for rep in 0..<reps {
          dumpNextNotification = rep == 0
          if scenario == "close" { kbOpen(); await Lab.sleep(1.0) } else { await Lab.sleep(0.5) }
          probe.start(name: "S1/\(v)_\(scenario)_\(rep)", columns: sessionColumns)
          probe.mark("trial \(v) \(scenario) \(rep)", frame: frameIndex)
          await Lab.sleep(0.1)
          switch scenario {
          case "open": kbOpen(); await Lab.sleep(1.0)
          case "close": dumpNextNotification = rep == 0; kbClose(); await Lab.sleep(1.0)
          default:
            textView.becomeFirstResponder(); await Lab.sleep(0.12); dumpNextNotification = rep == 0; textView.resignFirstResponder(); await Lab.sleep(1.2)
          }
          probe.stop()
          if scenario != "close" && kbIsOpen { kbClose(); await Lab.sleep(0.8) }
        }
        Lab.flushEvents()
      }
    }
    Lab.log("S1 done")
    if gt { await GroundTruth.shared.stop(name: "S1") }
    Lab.write("S1.done", "done")
    Lab.flushEvents()
  }

  // MARK: S1 gap follow-up: keyboard window pre-warming

  static var retainedKeyboardWindows: [UIWindow] = []
  static let emptyInputView: UIView = { let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 0)); v.autoresizingMask = []; return v }()
  var kbIsOpen: Bool { textView.isFirstResponder && textView.inputView == nil }

  func kbOpen() {
    switch Lab.arg("prewarm") {
    case "swap" where textView.isFirstResponder:
      textView.inputView = nil
      textView.reloadInputViews()
    default:
      textView.becomeFirstResponder()
    }
    if Lab.arg("prewarm") == "retain" {
      DispatchQueue.main.async {
        let kw = KB.keyboardWindow(scene: self.window?.windowScene)
        let reused = kw.map { w in LabView.retainedKeyboardWindows.contains { $0 === w } } ?? false
        Lab.log("prewarm retain: keyboardWindow=\(kw.map { "\(Unmanaged.passUnretained($0).toOpaque())" } ?? "nil") reusedRetained=\(reused) retainedCount=\(LabView.retainedKeyboardWindows.count)")
        if let kw, !reused { LabView.retainedKeyboardWindows.append(kw) }
      }
    }
  }

  func kbClose() {
    switch Lab.arg("prewarm") {
    case "swap":
      textView.inputView = LabView.emptyInputView
      textView.reloadInputViews()
    default:
      textView.resignFirstResponder()
    }
  }

  func dumpHierarchy(label: String) {
    var out: [String] = ["=== hierarchy \(label) \(KB.describeOOP())"]
    out.append("accessory.window=\(Priv.cls(accessory.window)) ancestors:")
    for (i, a) in KB.ancestors(accessory).enumerated() {
      out.append("  [\(i)] \(Priv.cls(a)) frame=\(fmt(a.frame)) bounds=\(fmt(a.bounds)) layer=\(Priv.cls(a.layer))")
    }
    let kw = KB.keyboardWindow(scene: window?.windowScene)
    out.append("sceneRoute keyboardWindow=\(Priv.cls(kw)) frame=\(fmt(kw?.frame ?? .zero)) level=\(kw?.windowLevel.rawValue ?? -1) hidden=\(kw?.isHidden ?? true) sameAsAccessoryWindow=\(kw === accessory.window) screen=\(kw.map { "\(Unmanaged.passUnretained($0.screen).toOpaque())" } ?? "nil") appScreen=\(window.map { "\(Unmanaged.passUnretained($0.screen).toOpaque())" } ?? "nil") rootVC=\(Priv.cls(kw?.rootViewController)) scene=\(Priv.cls(kw?.windowScene))")
    out.append("hostViaWindow=\(Priv.cls(KB.hostViaWindow(kw))) hostViaAccessory=\(Priv.cls(KB.hostViaAccessory(accessory))) same=\(KB.hostViaWindow(kw) === KB.hostViaAccessory(accessory))")
    if let kw { KB.tree(kw, maxDepth: 9, into: &out) } else if let top = KB.ancestors(accessory).last { KB.tree(top, maxDepth: 9, into: &out) }
    // Window's layer tree classes for remote/hosted layers
    if let host = hostView() {
      var lines: [String] = []
      func walk(_ l: CALayer, _ d: Int) {
        lines.append(String(repeating: "  ", count: d) + "\(Priv.cls(l)) frame=\(fmt(l.frame)) bounds=\(fmt(l.bounds)) delegate=\(Priv.cls(l.delegate as AnyObject?))")
        if d < 5 { for s in l.sublayers ?? [] { walk(s, d + 1) } }
      }
      walk(host.layer, 0)
      out.append("host layer tree:")
      out += lines
      let m = KB.screenRect(host.layer, presentation: false)
      let viaUIKit = host.convert(host.bounds, to: nil)
      out.append("host screenRect(model, CALayer to nil)=\(fmt(m)) UIView.convert(to: own window)=\(fmt(viaUIKit)) window.frame=\(fmt(host.window?.frame ?? .zero))")
    }
    Lab.log(out.joined(separator: "\n"))
    Lab.write("hierarchy_\(label).txt", out.joined(separator: "\n"))
  }

  // MARK: text view

  func textViewDidBeginEditing(_ textView: UITextView) { Lab.log("textView didBeginEditing") }
  func textViewDidEndEditing(_ textView: UITextView) { Lab.log("textView didEndEditing") }

  // MARK: S2 signal (b)

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === dragScroll, let host = hostView() else { return }
    lastScrollTop = Double(KB.screenRect(host.layer, presentation: false).minY)
    if mode == "S2pub", driver == "scroll" { applyKeyboardTop(screenY: lastScrollTop, source: "scroll") }
  }
}

struct SpringParams: CustomStringConvertible {
  var mass: CGFloat, stiffness: CGFloat, damping: CGFloat, duration: Double, v0: CGFloat
  var tf: CAMediaTimingFunction?
  static func system26(duration: Double) -> SpringParams {
    SpringParams(mass: 1, stiffness: 555.027, damping: 47.118, duration: duration, v0: 0, tf: CAMediaTimingFunction(name: .linear))
  }
  func make(keyPath: String, from: CGFloat) -> CASpringAnimation {
    let a = CASpringAnimation(keyPath: keyPath)
    a.mass = mass; a.stiffness = stiffness; a.damping = damping; a.initialVelocity = v0
    a.duration = duration
    a.timingFunction = tf ?? CAMediaTimingFunction(name: .linear)
    if #available(iOS 17.0, *) { a.allowsOverdamping = false }
    a.fromValue = from; a.toValue = 0
    a.isAdditive = true
    a.fillMode = .backwards
    return a
  }
  var description: String { "mass=\(mass) k=\(stiffness) c=\(damping) dur=\(duration) v0=\(v0) tf=\(tf.map { KB.cps($0) } ?? "nil")" }
}

/// Per-frame sample recorder written as CSV to Documents.
@MainActor
struct Probe {
  var recording = false
  var name = ""
  var columns: [String] = []
  var rows: [[Double]] = []
  var marks: [(Int, String)] = []

  mutating func start(name: String, columns: [String]) {
    if recording { stop() }
    self.name = name; self.columns = columns; rows = []; marks = []; recording = true
  }
  mutating func add(_ r: [Double]) { if recording { rows.append(r) } }
  mutating func mark(_ s: String, frame: Int) { if recording { marks.append((frame, String(format: "%.5f ", CACurrentMediaTime()) + s)) } }
  mutating func stop() {
    guard recording else { return }
    recording = false
    var text = columns.joined(separator: ",") + "\n"
    for r in rows { text += r.map { $0.isNaN ? "" : String(format: "%.4f", $0) }.joined(separator: ",") + "\n" }
    Lab.write("\(name).csv", text)
    Lab.write("\(name).marks", marks.map { "\($0.0) \($0.1)" }.joined(separator: "\n"))
  }
  /// For long sessions (S2/S3/S4): write everything so far, keep recording.
  func save() {
    guard recording else { return }
    var text = columns.joined(separator: ",") + "\n"
    for r in rows { text += r.map { $0.isNaN ? "" : String(format: "%.4f", $0) }.joined(separator: ",") + "\n" }
    Lab.write("\(name).csv", text)
    Lab.write("\(name).marks", marks.map { "\($0.0) \($0.1)" }.joined(separator: "\n"))
  }
}

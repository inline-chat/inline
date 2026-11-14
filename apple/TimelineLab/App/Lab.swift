import ObjectiveC
import QuartzCore
import UIKit

/// Launch configuration, logging, and file output.
@MainActor
enum Lab {
  static let args = ProcessInfo.processInfo.arguments

  static func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "-" + name), i + 1 < args.count else { return nil }
    return args[i + 1]
  }

  static let allModes = ["S1", "S2pub", "S2priv", "S4", "S3U", "S3C", "S3R", "S3L"]
  static func modeTitle(_ m: String) -> String {
    switch m {
    case "S1": return "S1 keyboard open/close"
    case "S2pub": return "S2 interactive (system)"
    case "S2priv": return "S2 interactive (private pan)"
    case "S4": return "S4 back-swipe/rotation"
    case "S3U": return "S3 engine U (scroll view driver)"
    case "S3C": return "S3 engine C (custom physics)"
    case "S3R": return "S3 reference UIScrollView"
    case "S3L": return "S3 2000-row list (realisation)"
    default: return m
    }
  }

  static var mode: String = arg("mode") ?? "S3C"
  static let autopush: Bool = (arg("autopush") ?? "1") == "1"
  static let autorun: Bool = arg("autorun") == "1"
  static let t0 = CACurrentMediaTime()

  static var events: [String] = []

  static func now() -> Double { CACurrentMediaTime() }

  static func log(_ s: String) {
    let line = String(format: "%.4f ", CACurrentMediaTime()) + s
    print("[LAB] " + line)
    events.append(line)
    if events.count > 4000 { flushEvents() }
  }

  static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

  static func write(_ name: String, _ text: String) {
    let url = docs.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }

  static func flushEvents() {
    let url = docs.appendingPathComponent("events.log")
    let text = events.joined(separator: "\n") + "\n"
    events.removeAll()
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
    } else {
      try? text.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
}

// MARK: - Private API helpers

@MainActor
enum Priv {
  static func classBool(_ cls: String, _ sel: String) -> Bool? {
    guard let c: AnyClass = NSClassFromString(cls) else { return nil }
    let s = NSSelectorFromString(sel)
    guard let m = class_getClassMethod(c, s) else { return nil }
    typealias F = @convention(c) (AnyClass, Selector) -> Bool
    return unsafeBitCast(method_getImplementation(m), to: F.self)(c, s)
  }

  static func obj(_ o: AnyObject?, _ sel: String) -> NSObject? {
    guard let o else { return nil }
    let s = NSSelectorFromString(sel)
    guard o.responds(to: s) else { return nil }
    return o.perform(s)?.takeUnretainedValue() as? NSObject
  }
  static func cls(named n: String) -> AnyObject? { NSClassFromString(n) }

  static func cls(_ o: AnyObject?) -> String { o.map { NSStringFromClass(type(of: $0)) } ?? "nil" }
}

// MARK: - Keyboard introspection

@MainActor
enum KB {
  static func keyboardWindow(scene: UIWindowScene?) -> UIWindow? {
    let ksd = Priv.obj(scene, "keyboardSceneDelegate")
    return Priv.obj(ksd, "keyboardWindow") as? UIWindow
  }

  /// Telegram's route: keyboard window → *InputSetContainerView → *InputSetHostView.
  static func hostViaWindow(_ window: UIWindow?) -> UIView? {
    guard let window else { return nil }
    for v in window.subviews where Priv.cls(v).hasSuffix("InputSetContainerView") {
      for s in v.subviews where Priv.cls(s).hasSuffix("InputSetHostView") { return s }
    }
    return nil
  }

  /// Accessory route: ancestors of our 1pt inputAccessoryView.
  static func ancestors(_ v: UIView?) -> [UIView] {
    var out: [UIView] = []
    var cur = v?.superview
    while let c = cur { out.append(c); cur = c.superview }
    return out
  }

  static func hostViaAccessory(_ acc: UIView?) -> UIView? {
    ancestors(acc).first { Priv.cls($0).hasSuffix("InputSetHostView") }
  }

  /// Screen-space rect of a layer, model or presentation, computed with CALayer conversion inside its own
  /// layer tree (never UIKit cross-window conversion, which returns CGRectNull across the keyboard's UIScreen).
  static func screenRect(_ layer: CALayer, presentation: Bool) -> CGRect {
    let l = presentation ? (layer.presentation() ?? layer) : layer
    return l.convert(l.bounds, to: nil)
  }

  static func describeOOP() -> String {
    let keys = ["inputUIOOP", "isInputSystemUI", "usesInputSystemUI", "usesLocalKeyboard", "isKeyboardProcess", "isRemoteEmojiCollectionViewEnabled"]
    return keys.map { "\($0)=\(Priv.classBool("UIKeyboard", $0).map { "\($0)" } ?? "n/a")" }.joined(separator: " ")
  }

  static func tree(_ v: UIView, depth: Int = 0, maxDepth: Int = 6, into out: inout [String]) {
    let pad = String(repeating: "  ", count: depth)
    let l = v.layer
    let anims = (l.animationKeys() ?? []).joined(separator: ",")
    out.append("\(pad)\(Priv.cls(v)) frame=\(fmt(v.frame)) bounds=\(fmt(v.bounds)) hidden=\(v.isHidden) alpha=\(v.alpha) layer=\(Priv.cls(l)) pos=\(fmt(l.position)) sublayerT=\(CATransform3DIsIdentity(l.sublayerTransform) ? "id" : "set") anims=[\(anims)]")
    // layer-only children (remote/hosting layers show up here)
    let viewLayers = Set(v.subviews.map { ObjectIdentifier($0.layer) })
    for sl in l.sublayers ?? [] where !viewLayers.contains(ObjectIdentifier(sl)) {
      out.append("\(pad)  ~layer \(Priv.cls(sl)) frame=\(fmt(sl.frame)) anims=[\((sl.animationKeys() ?? []).joined(separator: ","))]")
    }
    if depth < maxDepth { for s in v.subviews { tree(s, depth: depth + 1, maxDepth: maxDepth, into: &out) } }
  }

  /// Every CAAnimation on a layer and its descendants.
  static func dumpAnimations(_ layer: CALayer, label: String, depth: Int = 0, maxDepth: Int = 8, into out: inout [String]) {
    for key in layer.animationKeys() ?? [] {
      guard let a = layer.animation(forKey: key) else { continue }
      out.append("\(label) layer=\(Priv.cls(layer))@\(depth) key=\(key) \(describe(a, on: layer))")
    }
    if depth < maxDepth { for s in layer.sublayers ?? [] { dumpAnimations(s, label: label, depth: depth + 1, maxDepth: maxDepth, into: &out) } }
  }

  static func describe(_ a: CAAnimation, on layer: CALayer?) -> String {
    var s = "class=\(Priv.cls(a)) dur=\(a.duration) begin=\(a.beginTime) speed=\(a.speed) fill=\(a.fillMode.rawValue)"
    if let layer { s += String(format: " layerNow=%.4f", layer.convertTime(CACurrentMediaTime(), from: nil)) }
    if let tf = a.timingFunction { s += " tf=\(cps(tf))" } else { s += " tf=nil" }
    if let p = a as? CAPropertyAnimation { s += " keyPath=\(p.keyPath ?? "nil") additive=\(p.isAdditive) cumulative=\(p.isCumulative)" }
    if let b = a as? CABasicAnimation { s += " from=\(String(describing: b.fromValue)) to=\(String(describing: b.toValue)) by=\(String(describing: b.byValue))" }
    if let sp = a as? CASpringAnimation {
      s += " mass=\(sp.mass) stiffness=\(sp.stiffness) damping=\(sp.damping) v0=\(sp.initialVelocity) settling=\(sp.settlingDuration)"
      if #available(iOS 17.0, *) { s += " allowsOverdamping=\(sp.allowsOverdamping)" }
    }
    if let k = a as? CAKeyframeAnimation { s += " keyframes=\(k.values?.count ?? 0)" }
    if let g = a as? CAAnimationGroup { s += " group=[\((g.animations ?? []).map { describe($0, on: nil) }.joined(separator: " | "))]" }
    if let hfr = a.value(forKey: "highFrameRateReason") { s += " hfr=\(hfr)" }
    s += " fps=\(a.preferredFrameRateRange.minimum)-\(a.preferredFrameRateRange.maximum)"
    return s
  }

  nonisolated static func cps(_ tf: CAMediaTimingFunction) -> String {
    var out: [Float] = []
    for i in 1...2 { var p = [Float](repeating: 0, count: 2); tf.getControlPoint(at: i, values: &p); out += p }
    return out.map { String(format: "%.3f", $0) }.joined(separator: ",")
  }
}

func fmt(_ r: CGRect) -> String { String(format: "(%.1f,%.1f,%.1f,%.1f)", r.minX, r.minY, r.width, r.height) }
func fmt(_ p: CGPoint) -> String { String(format: "(%.1f,%.1f)", p.x, p.y) }
func f2(_ d: Double) -> String { String(format: "%.2f", d) }

import GameController

@MainActor
enum HWKB {
  static func methods(_ clsName: String, filter: String) -> [String] {
    guard let c: AnyClass = NSClassFromString(clsName) else { return ["<no \(clsName)>"] }
    var out: [String] = []
    for (target, prefix) in [(c, "-"), (object_getClass(c)!, "+")] {
      var n: UInt32 = 0
      if let list = class_copyMethodList(target, &n) {
        for i in 0..<Int(n) {
          let s = NSStringFromSelector(method_getName(list[i]))
          if s.lowercased().contains(filter) { out.append(prefix + s) }
        }
        free(list)
      }
    }
    return out.sorted()
  }

  static func describe() -> String {
    var s = "GCKeyboard.coalesced=\(GCKeyboard.coalesced.map { "\($0.vendorName ?? "?")" } ?? "nil")"
    for (cls, sel) in [("UIKeyboard", "isInHardwareKeyboardMode"), ("UIKeyboardImpl", "isHardwareKeyboardAttached"), ("UIKeyboardImpl", "isInHardwareKeyboardMode")] {
      s += " \(cls).\(sel)=\(Priv.classBool(cls, sel).map { "\($0)" } ?? "n/a")"
    }
    if let impl = Priv.obj(Priv.cls(named: "UIKeyboardImpl"), "activeInstance") ?? Priv.obj(Priv.cls(named: "UIKeyboardImpl"), "sharedInstance") {
      for sel in ["isInHardwareKeyboardMode", "hardwareKeyboardAttached", "isAttachedHardwareKeyboard", "isHardwareKeyboardAttachedNow", "isMinimized"] {
        let ss = NSSelectorFromString(sel)
        if impl.responds(to: ss), let m = class_getInstanceMethod(type(of: impl), ss) {
          typealias F = @convention(c) (AnyObject, Selector) -> Bool
          s += " impl.\(sel)=\(unsafeBitCast(method_getImplementation(m), to: F.self)(impl, ss))"
        }
      }
    }
    return s
  }

  static func forceSoftware() {
    let cls = Priv.cls(named: "UIKeyboardImpl")
    guard let impl = Priv.obj(cls, "activeInstance") ?? Priv.obj(cls, "sharedInstance") else { Lab.log("forceSoftware: no impl"); return }
    let s3 = NSSelectorFromString("setInHardwareKeyboardMode:forceRebuild:shouldMoveKeyboard:")
    if Lab.arg("forcesoftsel") == "rebuild", impl.responds(to: s3), let m = class_getInstanceMethod(type(of: impl), s3) {
      typealias F3 = @convention(c) (AnyObject, Selector, Bool, Bool, Bool) -> Void
      unsafeBitCast(method_getImplementation(m), to: F3.self)(impl, s3, false, true, true)
      Lab.log("forceSoftware: rebuild variant done")
      return
    }
    let mode = Lab.arg("forcesoftsel") ?? "setInHardwareKeyboardMode:"
    for sel in mode.split(separator: ",").map(String.init) {
      let ss = NSSelectorFromString(sel)
      if impl.responds(to: ss), let m = class_getInstanceMethod(type(of: impl), ss) {
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(impl, ss, false)
        Lab.log("forceSoftware: \(sel) NO on \(Priv.cls(impl))")
      } else { Lab.log("forceSoftware: \(sel) missing") }
    }
  }
}

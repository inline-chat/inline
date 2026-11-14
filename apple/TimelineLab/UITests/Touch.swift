import ObjectiveC
import XCTest

/// Multi-segment touch paths through XCTest's private XCPointerEventPath / XCSynthesizedEventRecord.
enum Touch {
  typealias InitPath = @convention(c) (Unmanaged<AnyObject>, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
  typealias MovePath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
  typealias LiftPath = @convention(c) (AnyObject, Selector, Double) -> Void
  typealias InitRecord = @convention(c) (Unmanaged<AnyObject>, Selector, NSString, Int) -> Unmanaged<AnyObject>
  typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
  typealias Synth = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> Bool

  static func alloc(_ cls: AnyClass) -> Unmanaged<AnyObject> {
    (cls as AnyObject).perform(NSSelectorFromString("alloc"))!
  }

  static func imp<T>(_ cls: AnyClass, _ sel: String, _ t: T.Type) -> (T, Selector) {
    let s = NSSelectorFromString(sel)
    return (unsafeBitCast(class_getMethodImplementation(cls, s)!, to: t), s)
  }

  /// A path: list of (point, time offset in seconds). First is touch-down; lift at the last offset (+ liftDelay).
  static func path(_ pts: [(CGPoint, Double)], liftDelay: Double = 0.0) -> AnyObject {
    let cls: AnyClass = NSClassFromString("XCPointerEventPath")!
    let (initF, initS) = imp(cls, "initForTouchAtPoint:offset:", InitPath.self)
    let p = initF(alloc(cls), initS, pts[0].0, pts[0].1).takeRetainedValue()
    let (moveF, moveS) = imp(cls, "moveToPoint:atOffset:", MovePath.self)
    for (pt, t) in pts.dropFirst() { moveF(p, moveS, pt, t) }
    let (liftF, liftS) = imp(cls, "liftUpAtOffset:", LiftPath.self)
    liftF(p, liftS, (pts.last?.1 ?? 0) + liftDelay)
    return p
  }

  /// Linear segments sampled every 1/120 s.  `legs`: [(to, duration)], starting at `from`.
  static func segments(from: CGPoint, legs: [(CGPoint, Double)], start: Double = 0) -> [(CGPoint, Double)] {
    var out: [(CGPoint, Double)] = [(from, start)]
    var cur = from, t = start
    for (to, d) in legs {
      if d <= 0 { continue }
      let n = max(1, Int(d * 120))
      for i in 1...n {
        let f = Double(i) / Double(n)
        out.append((CGPoint(x: cur.x + (to.x - cur.x) * f, y: cur.y + (to.y - cur.y) * f), t + d * f))
      }
      cur = to; t += d
    }
    return out
  }

  typealias SynthAsync = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void

  static func record(_ path: AnyObject, name: String) -> AnyObject {
    let rcls: AnyClass = NSClassFromString("XCSynthesizedEventRecord")!
    let (initF, initS) = imp(rcls, "initWithName:interfaceOrientation:", InitRecord.self)
    let rec = initF(alloc(rcls), initS, name as NSString, 1).takeRetainedValue()
    let (addF, addS) = imp(rcls, "addPointerEventPath:", AddPath.self)
    addF(rec, addS, path)
    return rec
  }

  /// Through XCUIDevice.eventSynthesizer (asynchronous, completion block).
  static func runViaSynthesizer(_ path: AnyObject, name: String, done: @escaping @Sendable () -> Void) -> Bool {
    let rec = record(path, name: name)
    guard let syn = (XCUIDevice.shared as NSObject).perform(NSSelectorFromString("eventSynthesizer"))?.takeUnretainedValue() else { return false }
    let sel = NSSelectorFromString("synthesizeEvent:completion:")
    guard let m = class_getMethodImplementation(type(of: syn), sel) else { return false }
    let block: @convention(block) (Bool, NSError?) -> Void = { ok, err in print("[UITEST] synth completion ok=\(ok) err=\(String(describing: err))"); done() }
    unsafeBitCast(m, to: SynthAsync.self)(syn, sel, rec, block as AnyObject)
    return true
  }

  static func run(_ path: AnyObject, name: String) -> Bool {
    let rcls: AnyClass = NSClassFromString("XCSynthesizedEventRecord")!
    let (initF, initS) = imp(rcls, "initWithName:interfaceOrientation:", InitRecord.self)
    let rec = initF(alloc(rcls), initS, name as NSString, 1).takeRetainedValue()
    let (addF, addS) = imp(rcls, "addPointerEventPath:", AddPath.self)
    addF(rec, addS, path)
    let (synF, synS) = imp(rcls, "synthesizeWithError:", Synth.self)
    return synF(rec, synS, nil)
  }
}

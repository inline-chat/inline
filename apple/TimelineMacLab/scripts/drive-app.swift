// Drives a running Inline debug app from outside: finds its main window, presses a sidebar row by title through
// Accessibility, posts trackpad gestures at the message list over the HID tap, and captures the window.
//   swift drive-app.swift <pid> window                 -> prints "<windowID> x y w h"
//   swift drive-app.swift <pid> open "<sidebar title>"
//   swift drive-app.swift <pid> fling <dy per event> <count> [momentum]
//   swift drive-app.swift <pid> shot <path>
import AppKit
import ApplicationServices
import Foundation

let args = CommandLine.arguments
let pid = pid_t(args[1])!
let command = args[2]

func mainWindow() -> (id: CGWindowID, bounds: CGRect)? {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
  let best = mine.max { a, b in
    let ra = CGRect(dictionaryRepresentation: a[kCGWindowBounds as String] as! CFDictionary)!
    let rb = CGRect(dictionaryRepresentation: b[kCGWindowBounds as String] as! CFDictionary)!
    return ra.width * ra.height < rb.width * rb.height
  }
  guard let best, let id = best[kCGWindowNumber as String] as? CGWindowID else { return nil }
  return (id, CGRect(dictionaryRepresentation: best[kCGWindowBounds as String] as! CFDictionary)!)
}

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, n as CFString, &v); return v }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
  for n in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
    if let s = attr(e, n) as? String, s == title { return e }
  }
  guard depth < 25 else { return nil }
  for c in kids(e) { if let f = find(c, title: title, depth: depth + 1) { return f } }
  return nil
}

switch command {
  case "window":
    guard let w = mainWindow() else { print("none"); exit(1) }
    print(w.id, Int(w.bounds.minX), Int(w.bounds.minY), Int(w.bounds.width), Int(w.bounds.height))
  case "open":
    let app = AXUIElementCreateApplication(pid)
    guard let window = attr(app, "AXMainWindow") as! AXUIElement?, let hit = find(window, title: args[3]) else { print("not found"); exit(1) }
    var target: AXUIElement? = hit
    // Press the nearest pressable ancestor (the sidebar row).
    for _ in 0 ..< 6 {
      guard let t = target else { break }
      var actions: CFArray?
      AXUIElementCopyActionNames(t, &actions)
      let names = (actions as? [String]) ?? []
      if names.contains(kAXPressAction) { AXUIElementPerformAction(t, kAXPressAction as CFString); print("pressed"); exit(0) }
      if (attr(t, kAXRoleAttribute) as? String) == "AXRow" || (attr(t, kAXRoleAttribute) as? String) == "AXCell" {
        AXUIElementSetAttributeValue(t, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        print("selected"); exit(0)
      }
      target = attr(t, kAXParentAttribute) as! AXUIElement?
    }
    print("no action"); exit(1)
  case "fling":
    guard let w = mainWindow() else { exit(1) }
    NSRunningApplication(processIdentifier: pid)?.activate()
    Thread.sleep(forTimeInterval: 0.4)
    // The message list: right of the sidebar, above the composer.
    let point = CGPoint(x: w.bounds.minX + w.bounds.width * 0.65, y: w.bounds.minY + w.bounds.height * 0.5)
    CGWarpMouseCursorPosition(point)
    let dy = Double(args[3])!, count = Int(args[4])!, momentum = args.count > 5 ? Double(args[5])! : 0
    func post(_ d: Double, _ phase: Int64, _ m: Int64) {
      let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(d.rounded()), wheel2: 0, wheel3: 0)!
      e.location = point
      e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
      e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: m)
      e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(d.rounded()))
      e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: d)
      e.post(tap: .cghidEventTap)
    }
    post(0, 128, 0); Thread.sleep(forTimeInterval: 1.0 / 120)
    post(dy, 1, 0)
    for _ in 1 ..< count { Thread.sleep(forTimeInterval: 1.0 / 120); post(dy, 2, 0) }
    Thread.sleep(forTimeInterval: 1.0 / 120); post(0, 4, 0)
    if momentum != 0 {
      var d = momentum
      post(d, 0, 1)
      while abs(d) > 0.5 { Thread.sleep(forTimeInterval: 1.0 / 60); d *= 0.95; post(d, 0, 2) }
      post(0, 0, 3)
    }
  case "shot":
    guard let w = mainWindow() else { exit(1) }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l\(w.id)", args[3]]
    try! task.run(); task.waitUntilExit()
  default:
    print("unknown command")
}

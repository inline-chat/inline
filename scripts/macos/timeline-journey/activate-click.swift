// One real click at a point (Cocoa global coordinates, origin at the main display's bottom left), posted at the HID
// event tap, then the pointer goes back where it was. A click is what makes a background app active and its window
// key (an app can't activate itself, and LaunchServices activation from a script is refused on current macOS).
// It clicks only when the frontmost window under the point belongs to the target process; otherwise it exits 3
// without clicking (a click on whatever else is there would act on another app).
// usage: activate-click <x> <y> <pid>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let x = Double(args[1]), let y = Double(args[2]), let pid = Int32(args[3]) else {
  FileHandle.standardError.write(Data("usage: activate-click <x> <y> <pid>\n".utf8))
  exit(2)
}
let mainHeight = NSScreen.screens.first?.frame.height ?? 0
let point = CGPoint(x: x, y: mainHeight - y)
// On-screen windows come front to back.
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let front = windows.first { info in
  guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha > 0
  else { return false }
  return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
    .contains(point)
}
guard let owner = front?[kCGWindowOwnerPID as String] as? Int32, owner == pid else {
  let name = front?[kCGWindowOwnerName as String] as? String ?? "nothing"
  FileHandle.standardError.write(Data("activate-click: \(name) is in front at the point, not pid \(pid); no click\n".utf8))
  exit(3)
}
let previous = CGEvent(source: nil)?.location ?? point
func post(_ type: CGEventType, at location: CGPoint) {
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved, at: point)
usleep(30_000)
post(.leftMouseDown, at: point)
usleep(40_000)
post(.leftMouseUp, at: point)
usleep(60_000)
post(.mouseMoved, at: previous)

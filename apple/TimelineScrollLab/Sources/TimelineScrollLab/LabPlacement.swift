import AppKit

/// Where the lab's windows open, so labs running side by side don't cover each other (see
/// `~/dev/inline-chat/.lab-screen/README.md`; this lane is slot E3): `--origin x,y` (global screen points, bottom-left),
/// else `TL_LAB_ORIGIN=x,y`, else E3's origin (1300, 40). Claim the slot before running, and POINTER too for
/// `--delivery hid`.
enum LabPlacement {
  static let origin: NSPoint = {
    let arguments = CommandLine.arguments
    let text = arguments.firstIndex(of: "--origin").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
      ?? ProcessInfo.processInfo.environment["TL_LAB_ORIGIN"]
    guard let text else { return NSPoint(x: 1300, y: 40) }
    let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 else { return NSPoint(x: 1300, y: 40) }
    return NSPoint(x: parts[0], y: parts[1])
  }()
}

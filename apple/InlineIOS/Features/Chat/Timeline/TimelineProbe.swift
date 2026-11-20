#if DEBUG
import InlineIOSUI
import InlineKit
import QuartzCore
import UIKit

/// Debug builds only, with `--timeline-harness-probe`: one line per display frame with where the list
/// is on screen, where it will settle, the finger and the keyboard, appended to
/// `Documents/timeline-probe.csv` once a second. Device runs read it back with
/// `devicectl device copy from`.
@MainActor
final class TimelineProbe: NSObject {
  static var isRequested: Bool { CommandLine.arguments.contains("--timeline-harness-probe") }

  private weak var list: TimelineListView<ChatRowID>?
  private weak var host: UIView?
  private weak var composer: UIView?
  private var link: CADisplayLink?
  private var lines: [String] = []
  private var lastFlush: CFTimeInterval = 0
  private let url: URL

  init(list: TimelineListView<ChatRowID>, host: UIView) {
    self.list = list
    self.host = host
    url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("timeline-probe.csv")
    super.init()
    try? FileManager.default.removeItem(at: url)
    lines.append("t,target,presented,settled,tracking,decelerating,fingerY,listMaxY,keyboardTop,composerTop,newestMaxY")
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    let maximum = Float(UIScreen.main.maximumFramesPerSecond)
    link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
    flush()
  }

  @objc private func tick(_ link: CADisplayLink) {
    guard let list, let host, let window = host.window else { return }
    let d = list.diagnostics
    let pan = list.panGestureRecognizer
    let finger = list.isTracking ? pan.location(in: window).y : -1
    let frame = list.convert(list.bounds, to: window)
    // The composer area is the list's bottom inset; its top edge on screen is where the list's
    // usable area ends. The keyboard's presented top is read from the window's keyboard layout guide.
    let guide = window.keyboardLayoutGuide.layoutFrame
    let keyboardTop = guide.height > 0 ? guide.minY : window.bounds.height
    if composer == nil, let root = host.superview { composer = Self.find(ComposeView.self, in: root) }
    var composerTop: CGFloat = -1
    if let composer, let layer = composer.layer.presentation(), let windowLayer = window.layer.presentation() {
      composerTop = layer.convert(layer.bounds, to: windowLayer).minY
    }
    // The bottom row's presented bottom: with `composerTop`, the gap a composer change should keep.
    var newestMaxY: CGFloat = -1
    if let last = list.layout.placements.last, let row = list.view(for: last.id),
       let layer = row.layer.presentation(), let windowLayer = window.layer.presentation()
    {
      newestMaxY = layer.convert(layer.bounds, to: windowLayer).maxY
    }
    lines.append(String(
      format: "%.5f,%.5f,%.2f,%.2f,%d,%d,%.1f,%.1f,%.1f,%.1f,%.1f", link.timestamp, link.targetTimestamp,
      d.presentedScrollPosition, d.scrollPosition, list.isTracking ? 1 : 0, list.isDecelerating ? 1 : 0, finger,
      frame.maxY, keyboardTop, composerTop, newestMaxY
    ))
    if link.timestamp - lastFlush > 1 { flush() }
  }

  private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews { if let match = find(type, in: subview) { return match } }
    return nil
  }

  private func flush() {
    lastFlush = CACurrentMediaTime()
    guard !lines.isEmpty else { return }
    let text = lines.joined(separator: "\n") + "\n"
    lines.removeAll(keepingCapacity: true)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(text.utf8))
      try? handle.close()
    } else {
      try? text.write(to: url, atomically: true, encoding: .utf8)
    }
  }
}
#endif

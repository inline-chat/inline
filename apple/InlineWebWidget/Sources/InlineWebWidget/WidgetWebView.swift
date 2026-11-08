#if os(macOS)
import AppKit
import WebKit

/// A web view that never scrolls itself in the list and records real user
/// input, which gates bridge actions. Script cannot fake these timestamps.
@MainActor
public final class WidgetWebView: WKWebView {
  public internal(set) var widgetKey: String?
  public private(set) var lastUserInteraction: Date?
  /// In the list, wheel events belong to the message list's scroll view.
  public var forwardsScrollWheel = true

  public override func mouseDown(with event: NSEvent) {
    lastUserInteraction = Date()
    super.mouseDown(with: event)
  }

  public override func rightMouseDown(with event: NSEvent) {
    lastUserInteraction = Date()
    super.rightMouseDown(with: event)
  }

  public override func keyDown(with event: NSEvent) {
    lastUserInteraction = Date()
    super.keyDown(with: event)
  }

  public override func scrollWheel(with event: NSEvent) {
    if forwardsScrollWheel, let scrollView = enclosingScrollView {
      scrollView.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }

  func resetInteraction() { lastUserInteraction = nil }

  /// WebContent process id, for spike measurements only (private KVC key).
  public var webContentProcessIdentifier: pid_t? {
    (value(forKey: "_webProcessIdentifier") as? NSNumber).map { pid_t($0.int32Value) }
  }
}
#endif

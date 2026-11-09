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

  /// WebKit's menu offers Reload, new windows and downloads, none of which a
  /// widget can use. Keep text items such as Copy, Look Up and Speech.
  public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    let blocked = ["Reload", "OpenLink", "OpenImage", "OpenFrame", "OpenMedia", "Download", "CopyImage", "CopyLink"]
    #if DEBUG
    let kept: Set<String> = ["WKMenuItemIdentifierInspectElement"]
    #else
    let kept: Set<String> = []
    #endif
    for item in menu.items {
      guard let identifier = item.identifier?.rawValue, !kept.contains(identifier) else { continue }
      if blocked.contains(where: identifier.contains) || identifier.contains("InspectElement") { menu.removeItem(item) }
    }
    while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
    while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    super.willOpenMenu(menu, with: event)
  }

  func resetInteraction() { lastUserInteraction = nil }

  /// WebContent process id, for spike measurements only (private KVC key).
  public var webContentProcessIdentifier: pid_t? {
    (value(forKey: "_webProcessIdentifier") as? NSNumber).map { pid_t($0.int32Value) }
  }
}
#endif

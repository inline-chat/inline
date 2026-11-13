import AppKit
import SwiftUI

enum ActivityJumpButtonKind {
  /// Unseen mentions and replies.
  case mention
  /// Unseen reactions to your messages.
  case reaction

  var tint: Color {
    switch self {
      case .mention: Color(nsColor: Theme.prominentColor)
      case .reaction: Color(nsColor: .systemPink)
    }
  }
}

/// Floating "@" or "♥" button above scroll-to-bottom. Shows how many items are unseen;
/// clicking jumps to the oldest one, right-clicking offers to mark them all read.
struct ActivityJumpButtonView: View {
  var kind: ActivityJumpButtonKind = .mention
  var isHovered = false
  var count = 0
  var themeRevision = 0
  var onClick: (() -> Void)?

  var body: some View {
    ChatFloatingButtonChrome(
      isHovered: isHovered,
      isVisible: count > 0,
      count: count,
      badgeTint: kind.tint,
      onClick: onClick
    ) {
      Group {
        switch kind {
          case .mention:
            Text("@").font(.system(size: ChatFloatingButtonMetrics.iconPointSize, weight: .semibold, design: .rounded))
              .offset(y: -0.5)
          case .reaction:
            Image(systemName: "heart.fill").font(.system(size: ChatFloatingButtonMetrics.iconPointSize - 1, weight: .medium))
        }
      }
      .foregroundStyle(kind.tint)
    }
  }
}

final class ActivityJumpButtonHostingView: NSControl {
  private let hostingView: NSHostingView<ActivityJumpButtonView>
  private var trackingArea: NSTrackingArea?

  var onClick: (() -> Void)? {
    didSet { hostingView.rootView.onClick = onClick }
  }

  var onMarkAllRead: (() -> Void)?

  private(set) var count = 0
  let kind: ActivityJumpButtonKind

  init(kind: ActivityJumpButtonKind) {
    self.kind = kind
    hostingView = NSHostingView(rootView: ActivityJumpButtonView(kind: kind))
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(hostingView)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingView.centerXAnchor.constraint(equalTo: centerXAnchor),
      hostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
      hostingView.widthAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
      hostingView.heightAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setCount(_ count: Int) {
    guard self.count != count else { return }
    self.count = count
    hostingView.rootView.count = count
    setAccessibilityHidden(count == 0)
  }

  override func accessibilityLabel() -> String? {
    switch kind {
      case .mention: count == 1 ? "1 unread mention" : "\(count) unread mentions"
      case .reaction: count == 1 ? "1 unread reaction" : "\(count) unread reactions"
    }
  }

  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard count > 0 else { return nil }
    let menu = NSMenu()
    let title = kind == .mention ? "Mark All Mentions as Read" : "Mark All Reactions as Seen"
    let item = NSMenuItem(title: title, action: #selector(markAllRead), keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: "checkmark.message", accessibilityDescription: nil)
    menu.addItem(item)
    return menu
  }

  @objc private func markAllRead() {
    onMarkAllRead?()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    hostingView.rootView.isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    hostingView.rootView.isHovered = false
  }
}

extension ActivityJumpButtonHostingView: AppThemeRefreshable {
  func refreshAppTheme() {
    hostingView.rootView.themeRevision &+= 1
  }
}

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
  @Environment(\.colorScheme) private var colorScheme
  var kind: ActivityJumpButtonKind = .mention
  var isHovered = false
  var count = 0
  var themeRevision = 0
  var onClick: (() -> Void)?

  private let buttonSize: CGFloat = Theme.scrollButtonSize

  private var isVisible: Bool { count > 0 }

  var body: some View {
    let button = Button(action: { onClick?() }) {
      Group {
        switch kind {
          case .mention:
            Text("@").font(.system(size: 14, weight: .semibold, design: .rounded))
          case .reaction:
            Image(systemName: "heart.fill").font(.system(size: 12, weight: .semibold))
        }
      }
        .foregroundStyle(kind.tint)
        .frame(width: buttonSize, height: buttonSize)
        .contentShape(.interaction, Circle())
    }
    .focusable(false)

    let styled: AnyView = if #available(macOS 26.0, *) {
      AnyView(
        button
          .buttonStyle(.plain)
          .glassEffect(
            Glass.regular
              .tint(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)) : nil)
              .interactive(),
            in: .circle
          )
      )
    } else {
      AnyView(
        button
          .buttonStyle(ScrollToBottomButtonStyle())
          .background(
            Circle()
              .fill(.ultraThinMaterial)
              .overlay(
                Circle().strokeBorder(
                  (colorScheme == .dark ? Color.white : Color.black).opacity(isHovered ? 0.22 : 0.1),
                  lineWidth: 0.5
                )
              )
              .shadow(color: .black.opacity(colorScheme == .dark ? 0.1 : 0.15), radius: 2, x: 0, y: -1)
          )
      )
    }

    return styled
      .overlay(alignment: .topTrailing) {
        if isVisible {
          Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(kind.tint))
            .offset(x: 5, y: -5)
            .allowsHitTesting(false)
        }
      }
      .opacity(isVisible ? 1 : 0)
      .scaleEffect(isVisible ? 1 : 0.92)
      .animation(.easeInOut(duration: 0.12), value: isHovered)
      .animation(.easeInOut(duration: 0.2), value: isVisible)
      .allowsHitTesting(isVisible)
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
      hostingView.widthAnchor.constraint(equalToConstant: Theme.scrollButtonSize),
      hostingView.heightAnchor.constraint(equalToConstant: Theme.scrollButtonSize),
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

import AppKit
import SwiftUI

final class ScrollToBottomButtonHostingView: NSControl {
  private let hostingView: NSHostingView<ScrollToBottomButtonView>
  private var isVisible = false
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet {
      hostingView.rootView.isHovered = isHovered
    }
  }
  private(set) var count = 0

  var onClick: (() -> Void)? {
    didSet {
      hostingView.rootView.onClick = onClick
    }
  }

  override init(frame: NSRect) {
    hostingView = NSHostingView(rootView: ScrollToBottomButtonView(isVisible: false))
    super.init(frame: frame)

    wantsLayer = true
    addSubview(hostingView)

    // Center the hosting view
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingView.centerXAnchor.constraint(equalTo: centerXAnchor),
      hostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
      hostingView.widthAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
      hostingView.heightAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
    ])

    alphaValue = 1
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingArea {
      removeTrackingArea(trackingArea)
    }

    let options: NSTrackingArea.Options = [
      .mouseEnteredAndExited,
      .activeAlways,
      .inVisibleRect,
    ]
    let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    setHover(true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    setHover(false)
  }

  override func accessibilityLabel() -> String? {
    NSLocalizedString("Scroll to bottom", comment: "Accessibility label")
  }

  override func accessibilityValue() -> Any? {
    guard count > 0 else { return nil }
    return count == 1 ? "1 unread message" : "\(count) unread messages"
  }

  func setVisibility(_ visible: Bool) {
    guard isVisible != visible else { return }
    isVisible = visible
    hostingView.rootView.isVisible = visible
  }

  /// Unread messages below; zero hides the badge.
  func setCount(_ count: Int) {
    guard self.count != count else { return }
    self.count = count
    hostingView.rootView.count = count
  }

  private func setHover(_ hovered: Bool) {
    guard isHovered != hovered else { return }
    isHovered = hovered
  }
}

extension ScrollToBottomButtonHostingView: AppThemeRefreshable {
  func refreshAppTheme() {
    var rootView = hostingView.rootView
    rootView.themeRevision &+= 1
    hostingView.rootView = rootView
  }
}

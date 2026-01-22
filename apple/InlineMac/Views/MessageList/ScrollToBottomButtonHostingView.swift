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
  private var hasUnread = false {
    didSet {
      hostingView.rootView.hasUnread = hasUnread
    }
  }

  var onClick: (() -> Void)? {
    didSet {
      hostingView.rootView.onClick = onClick
    }
  }

  override init(frame: NSRect) {
    hostingView = NSHostingView(rootView: ScrollToBottomButtonView())
    super.init(frame: frame)

    wantsLayer = true
    addSubview(hostingView)

    // Center the hosting view
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingView.centerXAnchor.constraint(equalTo: centerXAnchor),
      hostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
      hostingView.widthAnchor.constraint(equalToConstant: Theme.scrollButtonSize),
      hostingView.heightAnchor.constraint(equalToConstant: Theme.scrollButtonSize),
    ])

    alphaValue = 0
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

  func setVisibility(_ visible: Bool) {
    let hidden = !visible
    let targetOpacity: CGFloat = hidden ? 0 : 1
    guard alphaValue != targetOpacity else { return }

    isVisible = visible

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      alphaValue = targetOpacity
    }
  }

  func setHasUnread(_ hasUnread: Bool) {
    guard self.hasUnread != hasUnread else { return }
    self.hasUnread = hasUnread
  }

  private func setHover(_ hovered: Bool) {
    guard isHovered != hovered else { return }
    isHovered = hovered
  }
}

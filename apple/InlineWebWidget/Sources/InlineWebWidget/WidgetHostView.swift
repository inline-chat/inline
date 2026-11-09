#if os(macOS)
import AppKit
import WebKit

/// Message-row content for a widget: a header, then a snapshot, placeholder or
/// live web view. Manual layout; configuring a row never touches WebKit.
@MainActor
public final class WidgetHostView: NSView {
  public static let headerHeight: CGFloat = 24

  public private(set) var content: WidgetContent?
  public var onOpen: ((WidgetContent) -> Void)?

  private let titleLabel = NSTextField(labelWithString: "")
  private let openButton = NSButton(title: "Open", target: nil, action: nil)
  private let container = NSView()
  private let snapshotView = NSImageView()
  private let placeholder = NSTextField(labelWithString: "")
  private let fadeView = NSView()
  private weak var webView: WidgetWebView?
  private var isLive = false

  /// Height the web view should have; the page's measured height, capped.
  public var contentHeight: CGFloat = 240 {
    didSet { if contentHeight != oldValue { needsLayout = true } }
  }
  public var isClipped = false {
    didSet { fadeView.isHidden = !isClipped }
  }

  /// The header's trailing button, such as Show all for content past the inline cap.
  public var showsOpenButton = true {
    didSet {
      openButton.isHidden = !showsOpenButton
      needsLayout = true
    }
  }

  public var openButtonTitle: String {
    get { openButton.title }
    set { openButton.title = newValue }
  }

  public var contentWidth: CGFloat { max(bounds.width, 320) }
  /// The row's visible content area; snapshots are cropped to it.
  public var visibleContentHeight: CGFloat { max(0, bounds.height - Self.headerHeight) }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    openButton.bezelStyle = .accessoryBarAction
    openButton.controlSize = .small
    openButton.font = .systemFont(ofSize: 11)
    openButton.target = self
    openButton.action = #selector(openTapped)
    container.wantsLayer = true
    container.layer?.masksToBounds = true
    container.layer?.cornerRadius = 8
    container.layer?.borderWidth = 0.5
    container.layer?.borderColor = NSColor.separatorColor.cgColor
    snapshotView.imageScaling = .scaleNone
    snapshotView.imageAlignment = .alignTopLeft
    placeholder.font = .systemFont(ofSize: 12)
    placeholder.textColor = .tertiaryLabelColor
    placeholder.alignment = .center
    fadeView.wantsLayer = true
    fadeView.isHidden = true
    let gradient = CAGradientLayer()
    gradient.colors = [NSColor.windowBackgroundColor.withAlphaComponent(0).cgColor, NSColor.windowBackgroundColor.cgColor]
    gradient.startPoint = CGPoint(x: 0.5, y: 1)
    gradient.endPoint = CGPoint(x: 0.5, y: 0)
    fadeView.layer = gradient
    [titleLabel, openButton, container].forEach(addSubview)
    [snapshotView, placeholder, fadeView].forEach(container.addSubview)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  public override var isFlipped: Bool { true }

  /// Sets the row's content from first-frame data only.
  public func configure(content: WidgetContent, snapshot: NSImage?, contentHeight: CGFloat, isClipped: Bool) {
    self.content = content
    self.contentHeight = contentHeight
    self.isClipped = isClipped
    titleLabel.stringValue = content.title
    placeholder.stringValue = content.title
    snapshotView.image = snapshot
    snapshotView.isHidden = snapshot == nil
    placeholder.isHidden = snapshot != nil
    setAccessibilityLabel(content.title)
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    let width = bounds.width
    titleLabel.frame = NSRect(x: 2, y: 4, width: max(0, width - (showsOpenButton ? ceil(openButton.intrinsicContentSize.width) + 8 : 4)), height: 16)
    let buttonWidth = showsOpenButton ? ceil(openButton.intrinsicContentSize.width) : 0
    openButton.frame = NSRect(x: width - buttonWidth, y: 1, width: buttonWidth, height: 20)
    let content = NSRect(x: 0, y: Self.headerHeight, width: width, height: max(0, bounds.height - Self.headerHeight))
    container.frame = content
    let inner = container.bounds
    snapshotView.frame = inner
    placeholder.frame = NSRect(x: 0, y: inner.midY - 8, width: inner.width, height: 16)
    fadeView.frame = NSRect(x: 0, y: inner.height - 48, width: inner.width, height: 48)
    // The page lays out at full height and is clipped by the container.
    webView?.frame = NSRect(x: 0, y: 0, width: inner.width, height: max(inner.height, contentHeight))
  }

  // MARK: Live web view, driven by the coordinator

  func attach(_ webView: WidgetWebView) {
    self.webView = webView
    isLive = false
    webView.alphaValue = 0
    container.addSubview(webView, positioned: .below, relativeTo: fadeView)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  /// Called after the page reports its first paint, so the swap never flickers.
  func showLive() {
    guard let webView else { return }
    isLive = true
    webView.alphaValue = 1
    snapshotView.isHidden = true
    placeholder.isHidden = true
  }

  func detach(showing snapshot: NSImage?) {
    webView?.removeFromSuperview()
    webView = nil
    isLive = false
    if let snapshot { snapshotView.image = snapshot }
    snapshotView.isHidden = snapshotView.image == nil
    placeholder.isHidden = snapshotView.image != nil
  }

  public var webViewForTesting: WidgetWebView? { webView }

  @objc private func openTapped() {
    if let content { onOpen?(content) }
  }
}
#endif

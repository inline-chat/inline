import AppKit
import Quartz

final class VideoAttachmentView: NSView, QLPreviewItem {
  private let imageView: NSImageView
  private let closeButton: NSButton
  private let closeButtonBackground: NSVisualEffectView
  private let playOverlay: NSImageView
  private var onRemove: (() -> Void)?
  private let height: CGFloat
  private let maxWidth: CGFloat
  private let minWidth: CGFloat
  private var width: CGFloat = 80
  private let closeButtonSize: CGFloat = 20
  private let videoURL: URL?
  private var hoverTrackingArea: NSTrackingArea?

  init(
    thumbnail: NSImage?,
    videoURL: URL?,
    onRemove: @escaping () -> Void,
    height: CGFloat = 80,
    maxWidth: CGFloat = 180,
    minWidth: CGFloat = 60
  ) {
    self.onRemove = onRemove
    self.videoURL = videoURL
    self.height = height
    self.maxWidth = maxWidth
    self.minWidth = minWidth

    imageView = NSImageView(frame: .zero)
    imageView.image = thumbnail
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false

    let aspectRatio: CGFloat
    if let thumbnail {
      aspectRatio = thumbnail.size.width / max(thumbnail.size.height, 1)
    } else {
      aspectRatio = 16.0 / 9.0
    }
    let calculatedWidth = height * aspectRatio
    width = min(max(calculatedWidth, minWidth), maxWidth)

    closeButtonBackground = NSVisualEffectView(frame: .zero)
    closeButtonBackground.translatesAutoresizingMaskIntoConstraints = false

    closeButton = NSButton(frame: .zero)
    closeButton.translatesAutoresizingMaskIntoConstraints = false

    playOverlay = NSImageView(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage())
    playOverlay.translatesAutoresizingMaskIntoConstraints = false
    playOverlay.contentTintColor = .white
    playOverlay.imageScaling = .scaleProportionallyUpOrDown

    super.init(frame: .zero)

    configureCloseButtonBackground(closeButtonBackground)
    configureCloseButton(closeButton)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.masksToBounds = true
    focusRingType = .exterior

    addSubview(imageView)
    addSubview(closeButtonBackground)
    closeButtonBackground.addSubview(closeButton)
    addSubview(playOverlay)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

      closeButtonBackground.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      closeButtonBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      closeButtonBackground.widthAnchor.constraint(equalToConstant: closeButtonSize),
      closeButtonBackground.heightAnchor.constraint(equalToConstant: closeButtonSize),

      closeButton.centerXAnchor.constraint(equalTo: closeButtonBackground.centerXAnchor),
      closeButton.centerYAnchor.constraint(equalTo: closeButtonBackground.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 12),
      closeButton.heightAnchor.constraint(equalToConstant: 12),

      playOverlay.centerXAnchor.constraint(equalTo: centerXAnchor),
      playOverlay.centerYAnchor.constraint(equalTo: centerYAnchor),
      playOverlay.widthAnchor.constraint(equalToConstant: 24),
      playOverlay.heightAnchor.constraint(equalToConstant: 24),
    ])

    closeButton.target = self
    closeButton.action = #selector(removeButtonClicked)

    setCloseButtonVisible(false, animated: false)
  }

  private func configureCloseButtonBackground(_ view: NSVisualEffectView) {
    view.material = .hudWindow
    view.blendingMode = .withinWindow
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = closeButtonSize / 2
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
  }

  private func configureCloseButton(_ button: NSButton) {
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")
    button.imagePosition = .imageOnly
    button.contentTintColor = .labelColor
  }

  private func setCloseButtonVisible(_ visible: Bool, animated: Bool) {
    closeButton.isEnabled = visible
    let alpha: CGFloat = visible ? 1 : 0
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        if visible {
          closeButtonBackground.isHidden = false
        }
        closeButtonBackground.animator().alphaValue = alpha
        context.completionHandler = {
          if !visible {
            self.closeButtonBackground.isHidden = true
          }
        }
      }
    } else {
      closeButtonBackground.alphaValue = alpha
      closeButtonBackground.isHidden = !visible
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }

    let options: NSTrackingArea.Options = [
      .activeInKeyWindow,
      .mouseEnteredAndExited,
      .inVisibleRect,
    ]
    let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    setCloseButtonVisible(true, animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    setCloseButtonVisible(false, animated: true)
  }

  @objc private func removeButtonClicked() {
    onRemove?()
  }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    window?.makeFirstResponder(self)
    showQuickLookPreview()
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: width, height: height)
  }

  // MARK: Quick Look

  var previewItemTitle: String? { "Video" }
  @objc var previewItemURL: URL? { videoURL }

  private func showQuickLookPreview() {
    guard let videoURL else { return }
    if let panel = QLPreviewPanel.shared(), acceptsPreviewPanelControl(panel) {
      beginPreviewPanelControl(panel)
      panel.makeKeyAndOrderFront(nil)
    } else {
      NSWorkspace.shared.open(videoURL)
    }
  }
}

extension VideoAttachmentView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { videoURL == nil ? 0 : 1 }
  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { self }

  // Ensure Quick Look grabs control from this view immediately on first click
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    videoURL != nil
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
  }
}

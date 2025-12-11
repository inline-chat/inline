import AppKit
import Quartz

final class VideoAttachmentView: NSView, QLPreviewItem {
  private let imageView: NSImageView
  private let closeButton: NSButton
  private let playOverlay: NSImageView
  private var onRemove: (() -> Void)?
  private let height: CGFloat
  private let maxWidth: CGFloat
  private let minWidth: CGFloat
  private var width: CGFloat = 80
  private let videoURL: URL?

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
    imageView.image = thumbnail ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
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

    closeButton = NSButton(frame: .zero)
    closeButton.bezelStyle = .circular
    closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
    closeButton.isBordered = false
    closeButton.translatesAutoresizingMaskIntoConstraints = false

    playOverlay = NSImageView(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage())
    playOverlay.translatesAutoresizingMaskIntoConstraints = false
    playOverlay.contentTintColor = .white
    playOverlay.imageScaling = .scaleProportionallyUpOrDown

    super.init(frame: .zero)

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
    addSubview(closeButton)
    addSubview(playOverlay)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

      closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      closeButton.widthAnchor.constraint(equalToConstant: 16),
      closeButton.heightAnchor.constraint(equalToConstant: 16),

      playOverlay.centerXAnchor.constraint(equalTo: centerXAnchor),
      playOverlay.centerYAnchor.constraint(equalTo: centerYAnchor),
      playOverlay.widthAnchor.constraint(equalToConstant: 24),
      playOverlay.heightAnchor.constraint(equalToConstant: 24),
    ])

    closeButton.target = self
    closeButton.action = #selector(removeButtonClicked)
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

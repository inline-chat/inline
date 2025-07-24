import AppKit
import Quartz

class ImageAttachmentView: NSView, QLPreviewItem {
  private let imageView: NSImageView
  private let closeButton: NSButton
  private var onRemove: (() -> Void)?
  
  private let height: CGFloat = 80
  private var width: CGFloat = 80

  init(image: NSImage, onRemove: @escaping () -> Void) {
    self.onRemove = onRemove

    // Initialize imageView
    imageView = NSImageView(frame: .zero)
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    
    // calc width
    let aspectRatio = image.size.width / image.size.height
    width = height * aspectRatio

    // Initialize close button
    closeButton = NSButton(frame: .zero)
    closeButton.bezelStyle = .circular
    closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
    closeButton.isBordered = false
    closeButton.translatesAutoresizingMaskIntoConstraints = false

    super.init(frame: .zero)

    setupView()
    setupContextMenu()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.masksToBounds = true

    // Make the view focusable
    focusRingType = .exterior

    addSubview(imageView)
    addSubview(closeButton)

    NSLayoutConstraint.activate([
      // ImageView constraints
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      imageView.widthAnchor.constraint(equalToConstant: width),
      imageView.heightAnchor.constraint(equalToConstant: height),

      // Close button constraints
      closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      closeButton.widthAnchor.constraint(equalToConstant: 16),
      closeButton.heightAnchor.constraint(equalToConstant: 16),
    ])

    closeButton.target = self
    closeButton.action = #selector(removeButtonClicked)
  }

  private func setupContextMenu() {
    let menu = NSMenu()
    
    let removeItem = NSMenuItem(title: "Remove", action: #selector(removeButtonClicked), keyEquivalent: "")
    removeItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    menu.addItem(removeItem)
    
    let copyItem = NSMenuItem(title: "Copy", action: #selector(copyImage), keyEquivalent: "")
    copyItem.image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: nil)
    menu.addItem(copyItem)

    self.menu = menu
  }

  @objc private func removeButtonClicked() {
    onRemove?()
  }

  @objc private func copyImage() {
    guard let image = imageView.image else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([image])
  }

  // Override keyDown to handle delete key
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51 { // Delete key
      removeButtonClicked()
    } else if event.keyCode == 49 { // space key
      showQuickLookPreview()
    } else if event.keyCode == 53 { // Escape key
      showQuickLookPreview() // toggle
    } else {
      super.keyDown(with: event)
    }
  }

  // Override acceptsFirstResponder to allow focus

  override var acceptsFirstResponder: Bool {
    true
  }

  override func becomeFirstResponder() -> Bool {
    let success = super.becomeFirstResponder()
    if success {
      layer?.opacity = 0.8
    }
    return success
  }

  override func resignFirstResponder() -> Bool {
    let success = super.resignFirstResponder()
    if success {
      layer?.opacity = 1
    }
    return success
  }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    window?.makeFirstResponder(self)
    showQuickLookPreview()
  }

  // Quick Look
  private var tempImageURL: URL?
  var previewItemTitle: String? {
    "Image Preview"
  }

  // QLPreviewItem protocol implementation
  @objc var previewItemURL: URL? {
    if tempImageURL == nil {
      // Create temporary file for Quick Look
      if let image = imageView.image,
         let data = image.tiffRepresentation,
         let tempDir = try? FileManager.default.url(
           for: .itemReplacementDirectory,
           in: .userDomainMask,
           appropriateFor: FileManager.default.temporaryDirectory,
           create: true
         )
      {
        let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + ".tiff")
        try? data.write(to: tempFileURL)
        tempImageURL = tempFileURL
      }
    }
    return tempImageURL
  }

  private var sourceFrame: NSRect?

  @objc private func showQuickLookPreview() {
    guard let panel = QLPreviewPanel.shared() else { return }

    // Set the data source and delegate
    panel.dataSource = self
    panel.delegate = self

    // Store original frame for animation
    sourceFrame = window?.convertToScreen(convert(bounds, to: nil))

    if panel.isVisible {
      panel.close()
    } else {
      panel.makeKeyAndOrderFront(nil)
    }
  }

  deinit {
    // Clean up temporary file
    if let tempURL = tempImageURL {
      try? FileManager.default.removeItem(at: tempURL)
    }
  }
}

// Add QuickLook panel delegate support
extension ImageAttachmentView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    self
  }

  // Close
  func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    if event.type == .keyDown {
      switch event.keyCode {
        case 53: // Escape key
          panel.close()
          return true
        default:
          break
      }
    }
    return false
  }

  // Animation
  func previewPanel(
    _ panel: QLPreviewPanel!,
    transitionImageFor item: QLPreviewItem!,
    contentRect: UnsafeMutablePointer<NSRect>!
  ) -> Any! {
    imageView.image
  }

  func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
    sourceFrame ?? .zero
  }
}

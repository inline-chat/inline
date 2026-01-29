import AppKit
import InlineKit
import Logger
import Nuke
import NukeUI
import Quartz

final class NewPhotoView: NSView {
  private let imageView: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.translatesAutoresizingMaskIntoConstraints = false

    // Set a clear background initially
    view.layer?.backgroundColor = NSColor.clear.cgColor

    return view
  }()

  private let imageLayer: CALayer = {
    let layer = CALayer()
    layer.contentsGravity = .resizeAspectFill // This gives us cover behavior
    return layer
  }()

  private var currentImage: NSImage?

  // Add a separate background view for more reliable background coloring
  private let backgroundView: BasicView = {
    let view = BasicView()
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.backgroundColor = .gray.withAlphaComponent(0.05)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var fullMessage: FullMessage

  init(_ fullMessage: FullMessage, scrollState: MessageListScrollState) {
    self.fullMessage = fullMessage
    isScrolling = scrollState.isScrolling
    if fullMessage.message.isSticker == true {
      backgroundView.backgroundColor = .clear
    }

    super.init(frame: .zero)
    updateCornerRadii()
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Corner radius properties
  private let maskLayer = CAShapeLayer()
  var topLeftRadius: CGFloat = Theme.messageBubbleCornerRadius - 1
  var topRightRadius: CGFloat = Theme.messageBubbleCornerRadius - 1
  var bottomLeftRadius: CGFloat = 0.0
  var bottomRightRadius: CGFloat = 0.0

  var haveAddedImageView = false

  private func setupView() {
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.drawsAsynchronously = true
    layer?.shouldRasterize = true
    layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0

    translatesAutoresizingMaskIntoConstraints = false

    // Add background view first (below image view)
    addSubview(backgroundView)
    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // setupImage()
    updateImage()
    setupMasks()
    setupDragSource()
    setupClickGesture()

    showLoadingView()
  }

  private var imageConstraints: [NSLayoutConstraint] = []

  private func addImageView() {
    guard !haveAddedImageView else { return }
    haveAddedImageView = true
    addSubview(imageView)

    // Add the image layer to the image view
    imageView.layer?.addSublayer(imageLayer)

    // Remove existing constraints array if needed
    NSLayoutConstraint.deactivate(imageConstraints)
    imageConstraints = [
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]
    NSLayoutConstraint.activate(imageConstraints)
  }

  // Call for updating image when the message is updated
  public func update(with fullMessage: FullMessage) {
    let prev = self.fullMessage
    self.fullMessage = fullMessage
    updateCornerRadii()
    updateMasks()

    // Only reload if file id or image source has changed
    if
      prev.photoInfo?.id == fullMessage.photoInfo?.id,
      // and it wasn't downloaded to cache
      prev.photoInfo?.bestPhotoSize()?.localPath == fullMessage.photoInfo?.bestPhotoSize()?.localPath
    {
      Log.shared.debug("not reloading image view")
      return
    }

    updateImage()
  }

  private func updateCornerRadii() {
    let hasText = fullMessage.message.text?.isEmpty == false
    let hasTopHeader = fullMessage.message.repliedToMessageId != nil
      || fullMessage.message.forwardFromUserId != nil
    let bubbleRadius = Theme.messageBubbleCornerRadius - 1
    let topRadius = hasTopHeader ? 0 : bubbleRadius

    topLeftRadius = topRadius
    topRightRadius = topRadius

    if hasText {
      bottomLeftRadius = 0.0
      bottomRightRadius = 0.0
    } else {
      bottomLeftRadius = bubbleRadius
      bottomRightRadius = bubbleRadius
    }
  }

  private var wasLoadedWithPlaceholder = false
  private var isScrolling = false
  private func shouldLoadSync() -> Bool {
    !inLiveResize && !isScrolling
  }

  public func setIsScrolling(_ isScrolling: Bool) {
    self.isScrolling = isScrolling
  }

  private func updateImage() {
    if let url = imageLocalUrl() {
      let loadSync = shouldLoadSync()

      ImageCacheManager.shared.image(for: url, loadSync: loadSync) { [weak self] image in
        guard let self, let image else {
          self?.hideLoadingView()
          return
        }

        addImageView()

        if loadSync {
          setImage(image)
          hideLoadingView()
        } else {
          animateImageTransition(to: image)
        }
      }

    } else {
      // If no URL, trigger download and show loading
      if let photoInfo = fullMessage.photoInfo {
        Task.detached { [weak self] in
          guard let self else { return }
          await FileCache.shared.download(photo: photoInfo, reloadMessageOnFinish: fullMessage.message)
        }
      }

      showLoadingView()
      return
    }
  }

  private func setImage(_ image: NSImage) {
    currentImage = image
    imageLayer.contents = image
    updateImageLayerFrame()
  }

  private func animateImageTransition(to image: NSImage) {
    // With animation
    imageView.alphaValue = 0.0
    setImage(image)

    // Perform layout before animation
    needsLayout = true
    layoutSubtreeIfNeeded()

    DispatchQueue.main.async {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.imageView.animator().alphaValue = 1.0
      } completionHandler: {
        self.hideLoadingView()
      }
    }
  }

  private func updateImageLayerFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = imageView.bounds
    CATransaction.commit()
  }

  private func updateLayerScaling() {
    let scaleFactor = window?.backingScaleFactor ?? 2.0
    imageLayer.contentsScale = scaleFactor
    layer?.rasterizationScale = scaleFactor
  }

  private func showLoadingView() {
    print("showLoadingView")
    wasLoadedWithPlaceholder = true
    backgroundView.alphaValue = 1.0
  }

  private func hideLoadingView() {
    // Don't hide the background view, just make it transparent if needed
    backgroundView.alphaValue = 0.0
  }

  override func layout() {
    super.layout()
    updateMasks()
    updateImageLayerFrame()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateMasks()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateLayerScaling()
  }

  // Update the mask path based on current bounds
  private func updateMasks() {
    // Only update if we have valid dimensions
    if bounds.width > 0, bounds.height > 0 {
      maskLayer.frame = bounds
      maskLayer.path = createRoundedRectPath(for: bounds)
    }
  }

  private func setupMasks() {
    wantsLayer = true
    maskLayer.fillColor = NSColor.black.cgColor
    layer?.mask = maskLayer

    // Initial update of mask paths
    updateMasks()
  }

  private func createRoundedRectPath(for rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let width = rect.width
    let height = rect.height

    // Skip if dimensions are zero
    if width <= 0 || height <= 0 {
      return path
    }

    // In Cocoa/AppKit, (0,0) is at the BOTTOM-LEFT
    // So we need to adjust our mental model:
    // - "Top" corners are at y = height
    // - "Bottom" corners are at y = 0

    // Start at the bottom-left corner
    path.move(to: CGPoint(x: bottomLeftRadius, y: 0))

    // Bottom edge to bottom-right corner
    path.addLine(to: CGPoint(x: width - bottomRightRadius, y: 0))

    // Bottom-right corner arc
    path.addArc(
      center: CGPoint(x: width - bottomRightRadius, y: bottomRightRadius),
      radius: bottomRightRadius,
      startAngle: CGFloat(3 * Double.pi / 2),
      endAngle: 0,
      clockwise: false
    )

    // Right edge to top-right corner
    path.addLine(to: CGPoint(x: width, y: height - topRightRadius))

    // Top-right corner arc
    path.addArc(
      center: CGPoint(x: width - topRightRadius, y: height - topRightRadius),
      radius: topRightRadius,
      startAngle: 0,
      endAngle: CGFloat(Double.pi / 2),
      clockwise: false
    )

    // Top edge to top-left corner
    path.addLine(to: CGPoint(x: topLeftRadius, y: height))

    // Top-left corner arc
    path.addArc(
      center: CGPoint(x: topLeftRadius, y: height - topLeftRadius),
      radius: topLeftRadius,
      startAngle: CGFloat(Double.pi / 2),
      endAngle: CGFloat(Double.pi),
      clockwise: false
    )

    // Left edge back to start
    path.addLine(to: CGPoint(x: 0, y: bottomLeftRadius))

    // Bottom-left corner arc
    path.addArc(
      center: CGPoint(x: bottomLeftRadius, y: bottomLeftRadius),
      radius: bottomLeftRadius,
      startAngle: CGFloat(Double.pi),
      endAngle: CGFloat(3 * Double.pi / 2),
      clockwise: false
    )

    path.closeSubpath()
    return path
  }

  private func setupDragSource() {
    let dragGesture = NSPanGestureRecognizer(target: self, action: #selector(handleDragGesture(_:)))
    addGestureRecognizer(dragGesture)

    // ...
    unregisterDraggedTypes()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Check if we're in a drag operation
    if let currentEvent = NSApplication.shared.currentEvent {
      // Pass through for drag events that aren't our own drag gesture
      if currentEvent.type == .leftMouseDragged,
         dragStartPoint == nil
      {
        return nil
      }
    }
    return super.hitTest(point)
  }

  private func imageLocalUrl() -> URL? {
    guard let photoSize = fullMessage.photoInfo?.bestPhotoSize() else { return nil }

    if let localPath = photoSize.localPath {
      let url = FileCache.getUrl(for: .photos, localPath: localPath)
      return url
    }

    return nil
  }

  private func imageCdnUrl() -> URL? {
    guard let photoSize = fullMessage.photoInfo?.bestPhotoSize(),
          let cdnUrl = photoSize.cdnUrl else { return nil }

    return URL(string: cdnUrl)
  }

  // MARK: - Drag Source

  private var dragStartPoint: NSPoint?
  private let dragThreshold: CGFloat = 10.0

  @objc private func handleDragGesture(_ gesture: NSPanGestureRecognizer) {
    guard let url = imageLocalUrl() else { return }

    switch gesture.state {
      case .began:
        dragStartPoint = gesture.location(in: self)

      case .changed:
        guard let startPoint = dragStartPoint else { return }
        let currentPoint = gesture.location(in: self)
        let distance = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y)

        // Only start dragging if we've moved beyond the threshold
        if distance >= dragThreshold {
          dragStartPoint = nil // Reset to prevent multiple drag sessions

          let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
          draggingItem.setDraggingFrame(bounds, contents: currentImage)

          beginDraggingSession(
            with: [draggingItem],
            event: NSApp.currentEvent ?? NSEvent(),
            source: self
          )
        }

      case .ended, .cancelled:
        if dragStartPoint != nil {
          // finished half-way, open preview
          handleClickAction()
        }
        dragStartPoint = nil

      default:
        break
    }
  }

  // MARK: - QuickLook

  private var sourceFrame: NSRect?

  private var quickLookPanel: QLPreviewPanel? {
    QLPreviewPanel.shared()
  }

  private func setupClickGesture() {
    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
    addGestureRecognizer(clickGesture)
  }

  // In your PhotoView class
  override var acceptsFirstResponder: Bool {
    true
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      QLPreviewPanel.shared()?.updateController()
    }
    return became
  }

  private func handleClickAction() {
    guard let panel = QLPreviewPanel.shared() else { return }

    if panel.isVisible {
      panel.orderOut(nil)
    } else {
      // Update the responder chain
      window?.makeFirstResponder(self)
      panel.updateController()
      panel.makeKeyAndOrderFront(nil)
    }
  }

  @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
    handleClickAction()
  }
}

// MARK: - QLPreviewPanel

extension NewPhotoView {
  // Required for proper panel management
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    true
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
  }
}

// MARK: - QLPreviewPanelDataSource

extension NewPhotoView: QLPreviewPanelDataSource {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    self
  }
}

// MARK: - QLPreviewPanelDelegate

extension NewPhotoView: QLPreviewPanelDelegate {
  func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
    window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
  }

  // Doesn't work.
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

  func previewPanel(
    _ panel: QLPreviewPanel!,
    transitionImageFor item: QLPreviewItem!,
    contentRect: UnsafeMutablePointer<NSRect>!
  ) -> Any! {
    currentImage
  }
}

// MARK: - QLPreviewItem

extension NewPhotoView: QLPreviewItem {
  var previewItemURL: URL! {
    imageLocalUrl() ?? imageCdnUrl()
  }

  var previewItemTitle: String! {
    "Image Preview"
  }
}

// MARK: - NSDraggingSource

extension NewPhotoView: NSDraggingSource {
  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .outsideApplication ? .copy : []
  }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    alphaValue = 1.0
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    alphaValue = 1.0
  }
}

// MARK: - External Interface

extension NewPhotoView {
  @objc func copyImage() {
    guard
      let image = currentImage,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else {
      Task { @MainActor in
        ToastCenter.shared.showError("Failed to copy image")
      }
      return
    }

    let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0])

    // Write a temp file so apps that expect a file paste/drop can consume it.
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-image-\(UUID().uuidString)")
      .appendingPathExtension("png")

    do {
      try png.write(to: tempURL)
    } catch {
      Log.shared.error("Failed to write temp image for pasteboard: \(error)")
      Task { @MainActor in
        ToastCenter.shared.showError("Failed to copy image")
      }
      return
    }

    let item = NSPasteboardItem()
    item.setData(tiff, forType: .tiff)
    item.setData(png, forType: .png)
    item.setData(png, forType: NSPasteboard.PasteboardType("public.image"))
    if let jpeg {
      item.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
    }
    item.setString(tempURL.absoluteString, forType: .fileURL)

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([item])

    Task { @MainActor in
      ToastCenter.shared.showSuccess("Copied image")
    }
  }

  @objc func saveImage() {
    guard currentImage != nil else {
      Task { @MainActor in
        ToastCenter.shared.showError("Failed to save image")
      }
      return
    }
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.png, .jpeg]
    // Prefer original filename, otherwise generate a unique one to avoid overwriting.
    if let originalName = fullMessage.file?.fileName, !originalName.isEmpty {
      savePanel.nameFieldStringValue = originalName
    } else {
      let ext: String = {
        if let localExt = imageLocalUrl()?.pathExtension, !localExt.isEmpty {
          return localExt
        }
        return "png"
      }()
      savePanel.nameFieldStringValue = "inline-\(UUID().uuidString.prefix(8)).\(ext)"
    }
    savePanel.begin { response in
      guard response == .OK, let url = savePanel.url else { return }

      // copy it from local url
      guard let localUrl = self.imageLocalUrl() else {
        Task { @MainActor in
          ToastCenter.shared.showError("Image isn’t downloaded yet")
        }
        return
      }
      do {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
          try fileManager.removeItem(at: url)
        }
        try fileManager.copyItem(at: localUrl, to: url)
        Task { @MainActor in
          ToastCenter.shared.showSuccess("Image saved", actionTitle: "Show") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
      } catch {
        Log.shared.error("Failed to save image: \(error)")
        Task { @MainActor in
          ToastCenter.shared.showError("Failed to save image")
        }
      }
    }
  }
}

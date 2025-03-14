
import AppKit
import InlineKit
import Logger
import Nuke
import NukeUI
import Quartz

final class NewPhotoView: NSView {
  private let imageView: NSImageView = {
    let view = NSImageView()
    view.wantsLayer = true
    view.imageScaling = .scaleProportionallyUpOrDown
    view.translatesAutoresizingMaskIntoConstraints = false

    // Set a clear background initially
    view.layer?.backgroundColor = NSColor.clear.cgColor

    // Disable the built-in drag behavior so chat view's drop handler works
    view.unregisterDraggedTypes()
    view.isEditable = false // Prevents drag-to-change-image behavior

    return view
  }()

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

  init(_ fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Corner radius properties
  private let maskLayer = CAShapeLayer()
  let topLeftRadius: CGFloat = Theme.messageBubbleCornerRadius - 1
  let topRightRadius: CGFloat = Theme.messageBubbleCornerRadius - 1
  let bottomLeftRadius: CGFloat = 2.0
  let bottomRightRadius: CGFloat = 2.0

  var haveAddedImageView = false

  private func setupView() {
    wantsLayer = true
    // translatesAutoresizingMaskIntoConstraints = false

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

  private var wasLoadedWithPlaceholder = false

  private func updateImage() {
    if let url = imageLocalUrl() {
      // Set URL
      guard let image = NSImage(contentsOf: url) else { return }

      // Add image view
      addImageView()

      if wasLoadedWithPlaceholder {
        print("wasLoadedWithPlaceholder")

        // With animation
        imageView.alphaValue = 0.0
        imageView.image = image

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
      } else {
        // Without animation
        imageView.image = image
        hideLoadingView()
      }

    } else {
      // If no URL, trigger download and show loading
      if let photoInfo = fullMessage.photoInfo {
        Task {
          await FileCache.shared.download(photo: photoInfo, for: fullMessage.message)
        }
      }

      showLoadingView()
      return
    }
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
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateMasks()
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
          draggingItem.setDraggingFrame(bounds, contents: imageView.image)

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
    imageView.image
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
    guard let image = imageView.image else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([image])
  }

  @objc func saveImage() {
    guard let image = imageView.image else { return }
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.png, .jpeg]
    savePanel.nameFieldStringValue = fullMessage.file?.fileName ?? "image"
    savePanel.begin { response in
      guard response == .OK, let url = savePanel.url else { return }

      // copy it from local url
      guard let localUrl = self.imageLocalUrl() else { return }
      do {
        try FileManager.default.copyItem(at: localUrl, to: url)
      } catch {
        Log.shared.error("Failed to save image: \(error)")
      }
    }
  }
}

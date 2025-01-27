
import AppKit
import InlineKit
import Quartz // Add this import for Quick Look

final class PhotoView: NSView {
  private let imageView: NSImageView = {
    let view = NSImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
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
  let topLeftRadius: CGFloat = 4.0
  let topRightRadius: CGFloat = 4.0
  // minus 1px makes it look better bc of the 1px padding
  let bottomLeftRadius: CGFloat = Theme.messageIsBubble ? Theme.messageBubbleRadius - 1 : 4.0
  let bottomRightRadius: CGFloat = Theme.messageIsBubble ? Theme.messageBubbleRadius - 1 : 4.0

  private func setupView() {
    addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    setupMask()
    loadImage()
    setupDragSource()
    setupClickGesture()
  }

  override func layout() {
    super.layout()
    updateMask()
  }

  private func setupMask() {
    maskLayer.fillColor = NSColor.black.cgColor
    wantsLayer = true
    layer?.mask = maskLayer
  }

  private func updateMask() {
    let path = CGMutablePath()
    let width = bounds.width
    let height = bounds.height

    // Top-left corner
    path.move(to: CGPoint(x: topLeftRadius, y: 0))
    path.addArc(
      center: CGPoint(x: topLeftRadius, y: topLeftRadius),
      radius: topLeftRadius,
      startAngle: .pi * 3 / 2,
      endAngle: .pi,
      clockwise: true
    )

    // Left edge
    path.addLine(to: CGPoint(x: 0, y: height - bottomLeftRadius))

    // Bottom-left corner
    path.addArc(
      center: CGPoint(x: bottomLeftRadius, y: height - bottomLeftRadius),
      radius: bottomLeftRadius,
      startAngle: .pi,
      endAngle: .pi / 2,
      clockwise: true
    )

    // Bottom edge
    path.addLine(to: CGPoint(x: width - bottomRightRadius, y: height))

    // Bottom-right corner
    path.addArc(
      center: CGPoint(x: width - bottomRightRadius, y: height - bottomRightRadius),
      radius: bottomRightRadius,
      startAngle: .pi / 2,
      endAngle: 0,
      clockwise: true
    )

    // Right edge
    path.addLine(to: CGPoint(x: width, y: topRightRadius))

    // Top-right corner
    path.addArc(
      center: CGPoint(x: width - topRightRadius, y: topRightRadius),
      radius: topRightRadius,
      startAngle: 0,
      endAngle: .pi * 3 / 2,
      clockwise: true
    )

    path.closeSubpath()
    maskLayer.path = path
  }

  private func setupDragSource() {
    let dragGesture = NSPanGestureRecognizer(target: self, action: #selector(handleDragGesture(_:)))
    addGestureRecognizer(dragGesture)
  }

  private func imageUrl() -> URL? {
    guard let file = fullMessage.file else { return nil }
    let url = if let tempUrl = file.temporaryUrl {
      URL(string: tempUrl)
    } else {
      file.getLocalURL()
    }
    return url
  }

  private func loadImage() {
    guard let url = imageUrl() else { return }
    guard let image = NSImage(contentsOf: url) else {
      return
    }
    imageView.image = image
  }

  // MARK: - Drag Source

  private var dragStartPoint: NSPoint?
  private let dragThreshold: CGFloat = 10.0

  @objc private func handleDragGesture(_ gesture: NSPanGestureRecognizer) {
    guard let url = imageUrl() else { return }

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

  @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
    guard let panel = quickLookPanel else { return }

    sourceFrame = window?.convertToScreen(convert(bounds, to: nil))

    if panel.isVisible {
      panel.orderOut(nil)
    } else {
      panel.makeKeyAndOrderFront(nil)
    }

    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
  }
}

// MARK: - QLPreviewPanelDataSource

extension PhotoView: QLPreviewPanelDataSource {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    self
  }
}

// MARK: - QLPreviewPanelDelegate

extension PhotoView: QLPreviewPanelDelegate {
  func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
    sourceFrame ?? .zero
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

extension PhotoView: QLPreviewItem {
  var previewItemURL: URL! {
    imageUrl()
  }

  var previewItemTitle: String! {
    "Image Preview"
  }
}

// MARK: - NSDraggingSource

extension PhotoView: NSDraggingSource {
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

// guard let file = fullMessage.file else { return }
// let url = if let tempUrl = file.temporaryUrl {
//  URL(string: tempUrl)
// } else {
//  file.getLocalURL()
// }
//
// guard let url else { return }
//
//
// let imageView = LazyImageView()
// imageView.priority = .high
// imageView.url = url
// imageView.translatesAutoresizingMaskIntoConstraints = false
// imageView.transition = .fadeIn(duration: 1.0)
////    let imageView = PhotoLazyImageView(url: url)
////    imageView.translatesAutoresizingMaskIntoConstraints = false
////    imageView.onStart = { _ in
////    }
////    imageView.onFailure = { _ in
////    }
////    imageView.onSuccess = { _ in
////    }
//
// self.imageView = imageView
//
//// Set corners based on bubble state
////    if hasBubble {
////      imageView.setCorners([
////        .radius(1.0, for: .topLeft),
////        .radius(1.0, for: .topRight),
////        .radius(Theme.messageBubbleRadius, for: .bottomLeft),
////        .radius(Theme.messageBubbleRadius, for: .bottomRight),
////      ])
////    } else {
////      imageView.setCorners(
////        ViewCorner.allCases.map { .radius(4.0, for: $0) }
////      )
////    }

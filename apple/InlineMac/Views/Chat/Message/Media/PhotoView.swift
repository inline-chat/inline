
import AppKit
import InlineKit

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

  private func setupView() {
    addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    loadImage()
    setupDragSource()
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

  @objc private func handleDragGesture(_ gesture: NSPanGestureRecognizer) {
    guard let url = imageUrl() else { return }

    switch gesture.state {
      case .began:
        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: imageView.image)

        beginDraggingSession(
          with: [draggingItem],
          event: NSApp.currentEvent ?? NSEvent(),
          source: self
        )
      default:
        break
    }
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
    alphaValue = 0.5
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

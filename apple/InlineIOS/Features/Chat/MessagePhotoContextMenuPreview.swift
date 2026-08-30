import InlineKit
import UIKit

@MainActor
final class MessagePhotoContextMenuPreview {
  let sourceImage: UIImage
  let stableID: Int64
  let photoID: Int64

  init?(message: FullMessage, sourceImage: UIImage) {
    guard let photoID = message.photoInfo?.id else { return nil }
    self.sourceImage = sourceImage
    stableID = message.id
    self.photoID = photoID
  }

  func matches(_ candidate: NewPhotoView) -> Bool {
    candidate.messageStableID == stableID &&
      candidate.photoStableID == photoID &&
      !candidate.isHidden &&
      candidate.alpha > 0 &&
      candidate.window != nil
  }
}

@MainActor
final class MessageContextMenuIdentifierView: ContextMenuIdentifierUIView {
  let photoPreview: MessagePhotoContextMenuPreview?

  init(
    accessoryView: UIView,
    configuration: ContextMenuAccessoryConfiguration,
    photoPreview: MessagePhotoContextMenuPreview?
  ) {
    self.photoPreview = photoPreview
    super.init(accessoryView: accessoryView, configuration: configuration)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@MainActor
final class MessagePhotoContextMenuPreviewController: UIViewController {
  private let sourceImage: UIImage

  init(sourceImage: UIImage, containerSize: CGSize) {
    self.sourceImage = sourceImage
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = Self.previewSize(imageSize: sourceImage.size, containerSize: containerSize)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let rootView = UIView()
    rootView.backgroundColor = .clear

    let imageView = UIImageView(image: sourceImage)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = 16
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = NSLocalizedString("Photo preview", comment: "Message photo context menu preview")
    rootView.addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: rootView.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])
    view = rootView
  }

  private static func previewSize(imageSize: CGSize, containerSize: CGSize) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return CGSize(width: 280, height: 280)
    }

    let maxWidth = min(560, max(220, containerSize.width - 48))
    let maxHeight = min(640, max(220, containerSize.height * 0.58))
    let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height)
    return CGSize(
      width: max(1, floor(imageSize.width * scale)),
      height: max(1, floor(imageSize.height * scale))
    )
  }
}

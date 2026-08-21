import AppKit
import InlineKit

final class RichBlockImageNodeView: RichBlockRenderableView {
  private let placeholder = NSView(frame: .zero)
  private let unavailableIcon: NSImageView = {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Image unavailable")
    return view
  }()

  private var photoView: SimplePhotoView?
  private var currentPhoto: PhotoInfo?

  init() {
    super.init(reuseKind: .image)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.masksToBounds = true
    placeholder.wantsLayer = true
    addSubview(placeholder)
    addSubview(unavailableIcon)
    setAccessibilityRole(.image)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .image(image) = node.kind else { return }
    apply(image: image, context: context)
  }

  func apply(image: RichBlockLayoutPlan.ImageNode, context: RichBlockRenderContext) {
    placeholder.layer?.backgroundColor = context.palette.placeholder.cgColor
    unavailableIcon.contentTintColor = context.palette.secondary.withAlphaComponent(0.7)
    unavailableIcon.isHidden = true

    switch image.state {
    case .pending:
      setAccessibilityLabel("Image loading")
      clearPhoto()
    case .unavailable:
      setAccessibilityLabel("Image unavailable")
      clearPhoto()
      unavailableIcon.isHidden = false
    case let .ready(photoInfo):
      setAccessibilityLabel("Image")
      if let photoView, currentPhoto?.id == photoInfo.id {
        if currentPhoto != photoInfo {
          photoView.update(with: photoInfo)
        }
      } else {
        clearPhoto()
        let view = SimplePhotoView(
          photoInfo: photoInfo,
          width: max(1, bounds.width),
          height: max(1, bounds.height),
          relatedMessage: context.relatedMessage,
          sizingMode: .manualFrames
        )
        photoView = view
        addSubview(view)
      }
      currentPhoto = photoInfo
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    placeholder.frame = bounds
    photoView?.applyManualLayoutFrame(bounds)
    unavailableIcon.frame = CGRect(
      x: floor((bounds.width - 24) / 2),
      y: floor((bounds.height - 24) / 2),
      width: 24,
      height: 24
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    clearPhoto()
  }

  private func clearPhoto() {
    photoView?.removeFromSuperview()
    photoView = nil
    currentPhoto = nil
  }
}

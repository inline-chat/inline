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
  private var occurrence: BlockImageOccurrence?
  private var onImageClick: ((BlockImageOccurrence) -> Void)?
  private var previewSpinner: NSProgressIndicator?

  var displayedImage: NSImage? { photoView?.displayedImage }
  var canOpenPreview: Bool {
    occurrence?.photo.hasDisplayablePreview == true && onImageClick != nil
  }

  func matches(photoID: Int64) -> Bool { occurrence?.photo.id == photoID }

  init() {
    super.init(reuseKind: .image)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.masksToBounds = true
    placeholder.wantsLayer = true
    addSubview(placeholder)
    addSubview(unavailableIcon)
    setAccessibilityRole(.image)
    addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openImage)))
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
      occurrence = BlockImageOccurrence(path: image.path, photo: photoInfo)
      onImageClick = context.interactions.onImageClick
    }
    window?.invalidateCursorRects(for: self)
    needsLayout = true
  }

  @objc private func openImage() {
    guard let occurrence, occurrence.photo.hasDisplayablePreview else { return }
    onImageClick?(occurrence)
  }

  override func accessibilityPerformPress() -> Bool {
    guard canOpenPreview else { return false }
    openImage()
    return true
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    if occurrence?.photo.hasDisplayablePreview == true { addCursorRect(bounds, cursor: .pointingHand) }
  }

  func setPreviewLoading(_ loading: Bool) {
    if loading, previewSpinner == nil {
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.isDisplayedWhenStopped = false
      addSubview(spinner)
      previewSpinner = spinner
    }
    if loading, let previewSpinner {
      addSubview(previewSpinner, positioned: .above, relativeTo: nil)
      previewSpinner.startAnimation(nil)
    } else {
      previewSpinner?.stopAnimation(nil)
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
    previewSpinner?.frame = CGRect(x: floor((bounds.width - 16) / 2), y: floor((bounds.height - 16) / 2),
                                  width: 16, height: 16)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    clearPhoto()
  }

  private func clearPhoto() {
    setPreviewLoading(false)
    photoView?.removeFromSuperview()
    photoView = nil
    currentPhoto = nil
    occurrence = nil
    onImageClick = nil
  }
}

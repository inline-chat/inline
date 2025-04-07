import InlineKit
import InlineProtocol
import Logger
import Nuke
import NukeExtensions
import NukeUI
import QuickLook
import SwiftUI
import UIKit

final class NewPhotoView: UIView, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  // MARK: - Properties

  private var fullMessage: FullMessage

  private let maxWidth: CGFloat = 280
  private let maxHeight: CGFloat = 400
  private let minWidth: CGFloat = 180
  private let cornerRadius: CGFloat = 16.0
  private let maskLayer = CAShapeLayer()

  var isSticker: Bool {
    fullMessage.message.isSticker == true
  }

  private var hasText: Bool {
    fullMessage.message.text?.isEmpty == false
  }

  private var hasReply: Bool {
    fullMessage.message.repliedToMessageId != nil
  }

  private struct ImageDimensions {
    let width: CGFloat
    let height: CGFloat
  }

  let imageView: LazyImageView = {
    let view = LazyImageView()
    view.contentMode = .scaleAspectFit
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false

    let activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.startAnimating()
    view.placeholderView = activityIndicator

    return view
  }()

  private var imageConstraints: [NSLayoutConstraint] = []

  // MARK: - Initialization

  init(_ fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)

    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func calculateImageDimensions(width: Int, height: Int) -> ImageDimensions {
    let aspectRatio = CGFloat(width) / CGFloat(height)

    var calculatedWidth: CGFloat
    var calculatedHeight: CGFloat

    if width > height {
      calculatedWidth = min(maxWidth, CGFloat(width))
      calculatedHeight = calculatedWidth / aspectRatio
    } else {
      calculatedHeight = min(maxHeight, CGFloat(height))
      calculatedWidth = calculatedHeight * aspectRatio
    }

    if calculatedHeight > maxHeight {
      calculatedHeight = maxHeight
      calculatedWidth = calculatedHeight * aspectRatio
    }

    if calculatedWidth > maxWidth {
      calculatedWidth = maxWidth
      calculatedHeight = calculatedWidth / aspectRatio
    }

    return ImageDimensions(
      width: isSticker ? calculatedWidth / 2 : calculatedWidth,
      height: isSticker ? calculatedHeight / 2 : calculatedHeight
    )
  }

  private func setupImageConstraints() {
    if !imageConstraints.isEmpty {
      NSLayoutConstraint.deactivate(imageConstraints)
      imageConstraints.removeAll()
    }

    guard let photoInfo = fullMessage.photoInfo,
          let width = photoInfo.bestPhotoSize()?.width,
          let height = photoInfo.bestPhotoSize()?.height
    else {
      let size = minWidth
      imageConstraints = [
        widthAnchor.constraint(equalToConstant: size),
        heightAnchor.constraint(equalToConstant: size),

        imageView.topAnchor.constraint(equalTo: topAnchor),
        imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
        imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ]
      NSLayoutConstraint.activate(imageConstraints)
      return
    }

    let dimensions = calculateImageDimensions(width: width, height: height)

    if !isSticker {
      let widthConstraint = widthAnchor.constraint(equalToConstant: dimensions.width)
      let heightConstraint = heightAnchor.constraint(equalToConstant: dimensions.height)

      let imageViewTopConstraint = imageView.topAnchor.constraint(equalTo: topAnchor)
      let imageViewLeadingConstraint = imageView.leadingAnchor.constraint(equalTo: leadingAnchor)
      let imageViewTrailingConstraint = imageView.trailingAnchor.constraint(equalTo: trailingAnchor)
      let imageViewBottomConstraint = imageView.bottomAnchor.constraint(equalTo: bottomAnchor)

      imageConstraints = [
        widthConstraint, heightConstraint,
        imageViewTopConstraint, imageViewLeadingConstraint, imageViewTrailingConstraint, imageViewBottomConstraint,
      ]
    }

    else {
      // Add extra vertical padding for PNG stickers
      let verticalPadding: CGFloat = 16.0

      let widthConstraint = widthAnchor.constraint(equalToConstant: dimensions.width)
      let heightConstraint = heightAnchor.constraint(equalToConstant: dimensions.height + (verticalPadding * 2))

      // Center the image view within the container with padding
      let imageViewTopConstraint = imageView.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding)
      let imageViewLeadingConstraint = imageView.leadingAnchor.constraint(equalTo: leadingAnchor)
      let imageViewTrailingConstraint = imageView.trailingAnchor.constraint(equalTo: trailingAnchor)
      let imageViewBottomConstraint = imageView.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: -verticalPadding
      )

      // Set a fixed height for the imageView to ensure it doesn't stretch
      let imageViewHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: dimensions.height)

      imageConstraints = [
        widthConstraint, heightConstraint,
        imageViewTopConstraint, imageViewLeadingConstraint, imageViewTrailingConstraint, imageViewBottomConstraint,
        imageViewHeightConstraint,
      ]
    }

    NSLayoutConstraint.activate(imageConstraints)
  }

  private func setupViews() {
    addSubview(imageView)

    setupImageConstraints()
    setupGestures()
    setupMask()
    updateImage()
  }

  private func setupGestures() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)
  }

  private func setupMask() {
    maskLayer.fillColor = UIColor.black.cgColor
    layer.mask = maskLayer
  }

//  private func updateMask() {
//    let width = bounds.width
//    let height = bounds.height
//
//    let shouldRoundTopCorners = hasText && !hasReply || !fullMessage.reactions.isEmpty
//    let shouldRoundBottomCorners = hasReply && !hasText || fullMessage.reactions.isEmpty
//    let shouldRoundAllCorners = !hasText && !hasReply || fullMessage.reactions.isEmpty
//
//    let roundingCorners: UIRectCorner = if shouldRoundAllCorners {
//      .allCorners
//    } else if shouldRoundTopCorners {
//      [.topLeft, .topRight]
//    } else if shouldRoundBottomCorners {
//      [.bottomLeft, .bottomRight]
//    } else {
//      []
//    }
//
//    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
//    let bezierPath = UIBezierPath(
//      roundedRect: bounds,
//      byRoundingCorners: roundingCorners,
//      cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
//    )
//
//    maskLayer.path = bezierPath.cgPath
//  }

  private func updateMask() {
    let width = bounds.width
    let height = bounds.height

    // Determine which corners to round based on message properties
    let hasReactions = !fullMessage.reactions.isEmpty

    let roundingCorners: UIRectCorner = if !hasText, !hasReply, !hasReactions {
      // No text and no reply - round all corners
      .allCorners
    } else if hasReactions {
      // No text but has reactions - round top corners only
      [.topLeft, .topRight]
    } else if hasText, !hasReply {
      // Has text but no reply - round top corners
      [.topLeft, .topRight]
    } else if hasReply, !hasText {
      // Has reply but no text - round bottom corners
      [.bottomLeft, .bottomRight]
    } else {
      // Default case - don't round any corners
      []
    }

    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let bezierPath = UIBezierPath(
      roundedRect: bounds,
      byRoundingCorners: roundingCorners,
      cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
    )

    maskLayer.path = bezierPath.cgPath
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateMask()
  }

  // MARK: - Image Loading

  public func update(with fullMessage: FullMessage) {
    let prev = self.fullMessage
    self.fullMessage = fullMessage

    if
      prev.photoInfo?.id == fullMessage.photoInfo?.id,
      prev.photoInfo?.bestPhotoSize()?.localPath == fullMessage.photoInfo?.bestPhotoSize()?.localPath
    {
      Log.shared.debug("not reloading image view")
      return
    }
    setupImageConstraints()
    updateImage()
  }

  private func updateImage() {
    if let url = imageLocalUrl() {
      imageView.url = url
    } else {
      if let photoInfo = fullMessage.photoInfo {
    
        Task.detached(priority: .userInitiated) { [weak self] in
          guard let self else { return }
          print("Calling updateImage \(fullMessage.message.messageId)")
          await FileCache.shared.download(photo: photoInfo, for: self.fullMessage.message)
          
          Task { @MainActor in
            if let newUrl = self.imageLocalUrl() {
              self.imageView.url = newUrl
            }
          }
        }
      }

      imageView.url = nil
    }
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

  // MARK: - User Interactions

  @objc private func handleTap() {
    guard fullMessage.message.isSticker != true else { return }
    guard imageLocalUrl() != nil || imageCdnUrl() != nil else { return }

    let previewController = QLPreviewController()
    previewController.dataSource = self
    previewController.delegate = self
    previewController.title = "Photo"

    previewController.modalPresentationStyle = .fullScreen

    if let viewController = findViewController() {
      viewController.present(previewController, animated: true)
    }
  }

  @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
    if let error {
      print("Error saving image: \(error.localizedDescription)")
    } else {
      print("Image saved successfully")
    }
  }

  private func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        return viewController
      }
      responder = nextResponder
    }
    return nil
  }

  // MARK: - First Responder

  override var canBecomeFirstResponder: Bool {
    true
  }

  // MARK: - QLPreviewControllerDataSource

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    if let localUrl = imageLocalUrl() {
      return localUrl as QLPreviewItem
    } else if let cdnUrl = imageCdnUrl() {
      return cdnUrl as QLPreviewItem
    }

    // Return a safe default
    return URL(fileURLWithPath: "") as QLPreviewItem
  }

  // MARK: - QLPreviewControllerDelegate

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    // Handle dismissal if needed
  }
}

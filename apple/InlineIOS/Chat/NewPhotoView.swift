import InlineKit
import InlineProtocol
import Logger
import Nuke
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

  private let imageView: UIImageView = {
    let view = UIImageView()
    view.contentMode = .scaleAspectFit
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let loadingIndicator: UIActivityIndicatorView = {
    let indicator = UIActivityIndicatorView(style: .medium)
    indicator.translatesAutoresizingMaskIntoConstraints = false
    indicator.hidesWhenStopped = true
    return indicator
  }()

  private var imageConstraints: [NSLayoutConstraint] = []
  private var wasLoadedWithPlaceholder = false

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

    return ImageDimensions(width: calculatedWidth, height: calculatedHeight)
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

    NSLayoutConstraint.activate(imageConstraints)
  }

  private func setupViews() {
    addSubview(imageView)

    addSubview(loadingIndicator)
    NSLayoutConstraint.activate([
      loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
      loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    setupImageConstraints()
    setupGestures()
    setupMask()
    updateImage()
  }

  private func setupGestures() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)

    let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    addGestureRecognizer(longPressGesture)
  }

  private func setupMask() {
    maskLayer.fillColor = UIColor.black.cgColor
    layer.mask = maskLayer
  }

  private func updateMask() {
    let width = bounds.width
    let height = bounds.height

    let shouldRoundTopCorners = hasText && !hasReply
    let shouldRoundBottomCorners = hasReply && !hasText
    let shouldRoundAllCorners = !hasText && !hasReply

    let roundingCorners: UIRectCorner = if shouldRoundAllCorners {
      .allCorners
    } else if shouldRoundTopCorners {
      [.topLeft, .topRight]
    } else if shouldRoundBottomCorners {
      [.bottomLeft, .bottomRight]
    } else {
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
      // Set URL
      guard let image = UIImage(contentsOfFile: url.path) else { return }

      if wasLoadedWithPlaceholder {
        print("wasLoadedWithPlaceholder")
        // With animation
        imageView.alpha = 0.0
        imageView.image = image

        setNeedsLayout()
        layoutIfNeeded()

        DispatchQueue.main.async {
          UIView.animate(withDuration: 0.25, animations: {
            self.imageView.alpha = 1.0
          }) { _ in
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
    loadingIndicator.startAnimating()
  }

  private func hideLoadingView() {
    loadingIndicator.stopAnimating()
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

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }

    let menu = UIMenuController.shared

    // Create menu items
    let copyItem = UIMenuItem(title: "Copy", action: #selector(copyImage))
    let saveItem = UIMenuItem(title: "Save", action: #selector(saveImage))

    menu.menuItems = [copyItem, saveItem]

    // Make this view the first responder to receive the action
    if !isFirstResponder {
      becomeFirstResponder()
    }

    // Show menu
    menu.showMenu(from: self, rect: bounds)
  }

  @objc func copyImage() {
    guard let image = imageView.image else { return }
    UIPasteboard.general.image = image
  }

  @objc func saveImage() {
    guard let image = imageView.image else { return }
    UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
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

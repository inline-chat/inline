import InlineKit
import InlineProtocol
import Logger
import Nuke
import NukeExtensions
import NukeUI
import SwiftUI
import UIKit

final class NewPhotoView: UIView {
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
    return view
  }()

  private lazy var progressView: CircularProgressView = {
    let view = CircularProgressView(size: 40, lineWidth: 3)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    view.isHidden = true
    return view
  }()

  private var imageConstraints: [NSLayoutConstraint] = []
  private var isLoading = false

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
    addSubview(progressView)

    NSLayoutConstraint.activate([
      progressView.centerXAnchor.constraint(equalTo: centerXAnchor),
      progressView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

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
    // Check if image is already uploaded by checking if it has a photoId
    let isUploaded = fullMessage.photoInfo?.photo.id != nil &&
      fullMessage.photoInfo?.photo.photoId != nil

    if let url = imageLocalUrl() {
      // Local image exists, load it
      showLoadingState(false)
      imageView.request = ImageRequest(
        url: url,
        processors: [.resize(width: 300)],
        priority: .high
      )
    } else {
      // Need to download or upload the image
      if let photoInfo = fullMessage.photoInfo {
        showLoadingState(true)

        Task.detached(priority: .userInitiated) { [weak self] in
          guard let self else { return }

          // Check if we need to upload or download
          if !isUploaded, photoInfo.bestPhotoSize()?.cdnUrl == nil {
            // Image needs to be uploaded
            do {
              // Wait for upload to complete
              _ = try await FileUploader.shared.waitForUpload(photoLocalId: photoInfo.photo.id ?? 0)

              Task { @MainActor in
                self.showLoadingState(false, animated: true)
              }
            } catch {
              Log.shared.error("Error waiting for upload: \(error)")
              Task { @MainActor in
                self.showLoadingState(false)
              }
            }
          } else {
            // Image needs to be downloaded
            await FileCache.shared.download(photo: photoInfo, for: fullMessage.message)

            Task { @MainActor in
              if let newUrl = self.imageLocalUrl() {
                self.imageView.request = ImageRequest(
                  url: newUrl,
                  processors: [.resize(width: 300)],
                  priority: .high
                )
                self.showLoadingState(false, animated: true)
              }
            }
          }
        }
      }

      imageView.url = nil
    }
  }

  private func showLoadingState(_ loading: Bool, animated: Bool = false) {
    guard loading != isLoading else { return }
    isLoading = loading

    if animated {
      if !loading {
        UIView.animate(withDuration: 0.3, animations: {
          self.progressView.alpha = 0
        }, completion: { _ in
          self.progressView.isHidden = true
          self.progressView.alpha = 1
          self.progressView.resetProgress()
        })
      } else {
        progressView.isHidden = false
        progressView.startIndeterminateAnimation()
      }
    } else {
      progressView.isHidden = !loading
      if loading {
        progressView.startIndeterminateAnimation()
      } else {
        progressView.resetProgress()
      }
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
    guard let url = imageLocalUrl() ?? imageCdnUrl() else { return }

    let imageViewer = ImageViewerController(
      imageURL: url,
      sourceView: imageView,
      sourceImage: imageView.imageView.image
    )

    findViewController()?.present(imageViewer, animated: false)
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
}

extension NewPhotoView {
  func getCurrentImage() -> UIImage? {
    imageView.imageView.image
  }
}

// MARK: - CircularProgressView

class CircularProgressView: UIView {
  private let progressLayer = CAShapeLayer()
  private let backgroundLayer = CAShapeLayer()
  private var animationLayer: CAShapeLayer?
  private let size: CGFloat
  private let lineWidth: CGFloat

  private var rotationAnimation: CABasicAnimation?
  private var dashAnimation: CABasicAnimation?

  init(size: CGFloat, lineWidth: CGFloat) {
    self.size = size
    self.lineWidth = lineWidth
    super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
    setupLayers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupLayers() {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let radius = (size - lineWidth) / 2

    let circlePath = UIBezierPath(
      arcCenter: center,
      radius: radius,
      startAngle: -(CGFloat.pi / 2),
      endAngle: 2 * CGFloat.pi - (CGFloat.pi / 2),
      clockwise: true
    )

    // Background track
    backgroundLayer.path = circlePath.cgPath
    backgroundLayer.fillColor = UIColor.clear.cgColor
    backgroundLayer.strokeColor = UIColor.lightGray.withAlphaComponent(0.2).cgColor
    backgroundLayer.lineWidth = lineWidth
    backgroundLayer.strokeEnd = 1.0
    layer.addSublayer(backgroundLayer)

    // Progress layer
    progressLayer.path = circlePath.cgPath
    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.strokeColor = UIColor.white.cgColor
    progressLayer.lineWidth = lineWidth
    progressLayer.strokeEnd = 0
    progressLayer.lineCap = .round
    layer.addSublayer(progressLayer)
  }

  func setProgress(_ progress: CGFloat, animated: Bool = true) {
    stopIndeterminateAnimation()

    if animated {
      let animation = CABasicAnimation(keyPath: "strokeEnd")
      animation.fromValue = progressLayer.strokeEnd
      animation.toValue = progress
      animation.duration = 0.3
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      progressLayer.strokeEnd = progress
      progressLayer.add(animation, forKey: "progressAnimation")
    } else {
      progressLayer.strokeEnd = progress
    }
  }

  func startIndeterminateAnimation() {
    stopIndeterminateAnimation()

    // Create animation layer if needed
    if animationLayer == nil {
      let center = CGPoint(x: bounds.midX, y: bounds.midY)
      let radius = (size - lineWidth) / 2

      let circlePath = UIBezierPath(
        arcCenter: center,
        radius: radius,
        startAngle: -(CGFloat.pi / 2),
        endAngle: 2 * CGFloat.pi - (CGFloat.pi / 2),
        clockwise: true
      )

      let animLayer = CAShapeLayer()
      animLayer.path = circlePath.cgPath
      animLayer.fillColor = UIColor.clear.cgColor
      animLayer.strokeColor = UIColor.white.cgColor
      animLayer.lineWidth = lineWidth
      animLayer.lineCap = .round
      animLayer.strokeEnd = 0.25
      layer.addSublayer(animLayer)

      animationLayer = animLayer
    }

    // Hide regular progress
    progressLayer.isHidden = true

    // Create rotation animation
    rotationAnimation = CABasicAnimation(keyPath: "transform.rotation.z")
    rotationAnimation?.fromValue = 0
    rotationAnimation?.toValue = 2 * CGFloat.pi
    rotationAnimation?.duration = 1.5
    rotationAnimation?.repeatCount = .infinity
    rotationAnimation?.timingFunction = CAMediaTimingFunction(name: .linear)

    animationLayer?.add(rotationAnimation!, forKey: "rotationAnimation")
  }

  func stopIndeterminateAnimation() {
    if let animLayer = animationLayer {
      animLayer.removeAllAnimations()
      animLayer.removeFromSuperlayer()
      animationLayer = nil
    }

    progressLayer.isHidden = false
  }

  func resetProgress() {
    stopIndeterminateAnimation()
    progressLayer.strokeEnd = 0
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    backgroundLayer.frame = bounds
    progressLayer.frame = bounds
    animationLayer?.frame = bounds

    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let radius = (bounds.width - lineWidth) / 2

    let circlePath = UIBezierPath(
      arcCenter: center,
      radius: radius,
      startAngle: -(CGFloat.pi / 2),
      endAngle: 2 * CGFloat.pi - (CGFloat.pi / 2),
      clockwise: true
    )

    backgroundLayer.path = circlePath.cgPath
    progressLayer.path = circlePath.cgPath
    animationLayer?.path = circlePath.cgPath
  }
}

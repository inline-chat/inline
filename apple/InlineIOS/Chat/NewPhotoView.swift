import InlineKit
import InlineProtocol
import Logger
import Nuke
import NukeExtensions
import NukeUI
import SwiftUI
import UIKit

// MARK: - Upload Progress View

struct UploadProgressView: View {
  let progress: Double
  let isProcessing: Bool
  let onCancel: () -> Void
  let shouldAnimate: Bool

  @State private var animatedProgress: Double = 0
  @State private var processingRotation: Double = 0
  @State private var scale: Double = 0.1
  @State private var opacity: Double = 0.0
  @State private var backgroundScale: Double = 0.1
  @State private var backgroundOpacity: Double = 0.0

  var body: some View {
    ZStack {
      // Background circle with opacity
      Circle()
        .fill(Color.black.opacity(0.6))
        .frame(width: 50, height: 50)
        .scaleEffect(backgroundScale)
        .opacity(backgroundOpacity)

      // Progress ring or processing indicator
      Circle()
        .stroke(Color.clear, lineWidth: 3)
        .frame(width: 40, height: 40)
        .overlay(
          Group {
            if isProcessing {
              // Processing spinner
              Circle()
                .trim(from: 0, to: 0.25)
                .stroke(
                  Color.white,
                  style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(processingRotation))
                .onAppear {
                  withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    processingRotation = 360
                  }
                }
            } else {
              // Progress ring that moves around the circle
              ZStack {
                // Background track (subtle)
                Circle()
                  .stroke(Color.white.opacity(0.3), lineWidth: 2)

                // Progress arc
                Circle()
                  .trim(from: 0, to: animatedProgress)
                  .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                  )
                  .rotationEffect(.degrees(-90)) // Start from top
                  .animation(.easeOut(duration: 0.6), value: animatedProgress)

                // Moving progress indicator (like moon around earth)
                if animatedProgress > 0 {
                  Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                    .offset(y: -17) // Position on the circle edge
                    .rotationEffect(.degrees(-90 + (animatedProgress * 360)))
                    .animation(.easeOut(duration: 0.6), value: animatedProgress)
                }
              }
            }
          }
        )
        .scaleEffect(scale)
        .opacity(opacity)

      // Cancel button (X)
      Button(action: onCancel) {
        Image(systemName: "xmark")
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.white)
      }
      .buttonStyle(PlainButtonStyle())
      .scaleEffect(scale)
      .opacity(opacity)
    }
    .onAppear {
      if shouldAnimate {
        // Animate in with spring effect
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0)) {
          backgroundScale = 1.0
          backgroundOpacity = 1.0
          scale = 1.0
          opacity = 1.0
        }
      } else {
        // Appear immediately without animation
        backgroundScale = 1.0
        backgroundOpacity = 1.0
        scale = 1.0
        opacity = 1.0
      }

      if !isProcessing {
        withAnimation(.easeOut(duration: 0.2)) {
          animatedProgress = progress
        }
      }
    }
    .onChange(of: progress) { newProgress in
      if !isProcessing {
        // Smooth progress animation
        withAnimation(.easeOut(duration: 0.4)) {
          animatedProgress = newProgress
        }

        // Check if upload is complete
        if newProgress >= 1.0 {
          // Complete the circle animation first, then fade out
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.5)) {
              backgroundScale = 0.1
              backgroundOpacity = 0.0
              scale = 0.1
              opacity = 0.0
            }
          }
        }
      }
    }
  }
}

final class NewPhotoView: UIView {
  // MARK: - Properties

  private var fullMessage: FullMessage

  private let maxWidth: CGFloat = 280
  private let maxHeight: CGFloat = 400
  private let minWidth: CGFloat = 180
  private let cornerRadius: CGFloat = 16.0
  private let maskLayer = CAShapeLayer()

  // Upload progress tracking
  private var uploadProgressView: UIHostingController<UploadProgressView>?
  private var isUploading: Bool = false
  private var uploadProgress: Double = 0.0

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
    setupUploadTracking()
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
    setupUploadTracking() // Re-setup upload tracking for updated message
  }

  private func updateImage() {
    if let url = imageLocalUrl() {
      imageView.request = ImageRequest(
        url: url,
        processors: [.resize(width: 300)],
        priority: .high
      )
    } else {
      if let photoInfo = fullMessage.photoInfo {
        Task.detached(priority: .userInitiated) { [weak self] in
          guard let self else { return }

          await FileCache.shared.download(photo: photoInfo, for: fullMessage.message)

          Task { @MainActor in
            if let newUrl = self.imageLocalUrl() {
              self.imageView.request = ImageRequest(
                url: newUrl,
                processors: [.resize(width: 300)],
                priority: .high
              )
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

  // MARK: - Upload Progress Tracking

  private func setupUploadTracking() {
    guard let photoInfo = fullMessage.photoInfo,
          let photoId = photoInfo.photo.id else { return }

    Task {
      let uploadId = "photo_\(photoId)"
      let status = await FileUploader.shared.getUploadStatus(for: uploadId)

      await MainActor.run {
        switch status {
          case let .inProgress(progress):
            showUploadProgress(progress: progress)
            setupProgressHandler(uploadId: uploadId)
          case .processing:
            showUploadProgress(progress: -1) // Processing state
            setupProgressHandler(uploadId: uploadId)
          case .completed, .notFound:
            hideUploadProgress()
        }
      }
    }
  }

  private func setupProgressHandler(uploadId: String) {
    Task {
      await FileUploader.shared.setProgressHandler(for: uploadId) { [weak self] progress in
        Task { @MainActor in
          self?.updateUploadProgress(progress: progress)
        }
      }
    }
  }

  private func showUploadProgress(progress: Double) {
    guard !isUploading else {
      updateUploadProgress(progress: progress)
      return
    }

    isUploading = true
    uploadProgress = progress

    let isProcessing = progress < 0
    let progressView = UploadProgressView(
      progress: max(0, progress), // Ensure progress is not negative for display
      isProcessing: isProcessing,
      onCancel: { [weak self] in
        self?.cancelUpload()
      },
      shouldAnimate: true
    )

    let hostingController = UIHostingController(rootView: progressView)
    hostingController.view.backgroundColor = UIColor.clear
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false

    addSubview(hostingController.view)

    NSLayoutConstraint.activate([
      hostingController.view.centerXAnchor.constraint(equalTo: centerXAnchor),
      hostingController.view.centerYAnchor.constraint(equalTo: centerYAnchor),
      hostingController.view.widthAnchor.constraint(equalToConstant: 50),
      hostingController.view.heightAnchor.constraint(equalToConstant: 50),
    ])

    uploadProgressView = hostingController
  }

  private func updateUploadProgress(progress: Double) {
    guard isUploading else { return }

    uploadProgress = progress

    // Update the SwiftUI view
    let isProcessing = progress < 0
    let progressView = UploadProgressView(
      progress: max(0, progress), // Ensure progress is not negative for display
      isProcessing: isProcessing,
      onCancel: { [weak self] in
        self?.cancelUpload()
      },
      shouldAnimate: false
    )

    uploadProgressView?.rootView = progressView

    // Hide progress view when upload completes (after completion animation)
    if progress >= 1.0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        self?.hideUploadProgress()
      }
    }
  }

  private func hideUploadProgress() {
    guard isUploading, let progressView = uploadProgressView else { return }

    isUploading = false

    // Animate out if not already animating
    UIView.animate(withDuration: 0.2, animations: {
      progressView.view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
      progressView.view.alpha = 0
    }) { _ in
      progressView.view.removeFromSuperview()
    }

    uploadProgressView = nil
  }

  private func cancelUpload() {
    guard let photoInfo = fullMessage.photoInfo,
          let photoId = photoInfo.photo.id else { return }

    Task {
      let uploadId = "photo_\(photoId)"
      await FileUploader.shared.cancel(uploadId: uploadId)

      await MainActor.run {
        hideUploadProgress()
      }
    }
  }
}

extension NewPhotoView {
  func getCurrentImage() -> UIImage? {
    imageView.imageView.image
  }
}

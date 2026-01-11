import Combine
import InlineKit
import InlineUI
import UIKit

final class NewVideoView: UIView {
  // MARK: - Properties

  private var fullMessage: FullMessage
  private let maxWidth: CGFloat = 280
  private let maxHeight: CGFloat = 400
  private let minWidth: CGFloat = 180
  private let cornerRadius: CGFloat = 16.0
  private let maskLayer = CAShapeLayer()
  private var imageConstraints: [NSLayoutConstraint] = []
  private var progressCancellable: AnyCancellable?
  private var isDownloading = false
  private var isPresentingViewer = false
  private var pendingViewerURL: URL?
  private var downloadProgress: Double = 0

  private var hasText: Bool {
    fullMessage.message.text?.isEmpty == false
  }

  private var hasReply: Bool {
    fullMessage.message.repliedToMessageId != nil
  }

  private var hasReactionsInBubble: Bool {
    !fullMessage.reactions.isEmpty && hasText
  }

  private struct ImageDimensions {
    let width: CGFloat
    let height: CGFloat
  }

  private let thumbnailView: PlatformPhotoView = {
    let view = PlatformPhotoView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.photoContentMode = .aspectFill
    return view
  }()

  private let overlayBackground: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    view.layer.masksToBounds = true
    return view
  }()

  private let overlayIconView: UIImageView = {
    let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    let imageView = UIImageView(image: UIImage(systemName: "play.fill", withConfiguration: config))
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.tintColor = .white
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()

  private let overlaySpinner: UIActivityIndicatorView = {
    let view = UIActivityIndicatorView(style: .medium)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.color = .white
    view.hidesWhenStopped = true
    return view
  }()

  private let downloadProgressView: CircularProgressHostingView = {
    let view = CircularProgressHostingView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    return view
  }()

  private let cancelDownloadButton: UIButton = {
    let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
    button.tintColor = .white
    button.isHidden = true
    button.accessibilityLabel = "Cancel download"
    return button
  }()

  private let durationBadge: PillLabel = {
    let label = PillLabel()
    label.font = .systemFont(ofSize: 10, weight: .semibold)
    label.textColor = .white
    label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    label.layer.masksToBounds = true
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isHidden = true
    return label
  }()

  private final class PillLabel: UILabel {
    private let textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
      super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
      let size = super.intrinsicContentSize
      return CGSize(
        width: size.width + textInsets.left + textInsets.right,
        height: size.height + textInsets.top + textInsets.bottom
      )
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      layer.cornerRadius = bounds.height / 2
    }
  }

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

  deinit {
    progressCancellable?.cancel()
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

    if calculatedWidth < minWidth {
      calculatedWidth = minWidth
      calculatedHeight = calculatedWidth / aspectRatio
    }

    return ImageDimensions(width: calculatedWidth, height: calculatedHeight)
  }

  private func setupVideoConstraints() {
    if !imageConstraints.isEmpty {
      NSLayoutConstraint.deactivate(imageConstraints)
      imageConstraints.removeAll()
    }

    guard let width = fullMessage.videoInfo?.video.width,
          let height = fullMessage.videoInfo?.video.height,
          width > 0,
          height > 0
    else {
      let size = minWidth
      imageConstraints = [
        widthAnchor.constraint(equalToConstant: size),
        heightAnchor.constraint(equalToConstant: size),

        thumbnailView.topAnchor.constraint(equalTo: topAnchor),
        thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor),
        thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor),
        thumbnailView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ]
      NSLayoutConstraint.activate(imageConstraints)
      return
    }

    let dimensions = calculateImageDimensions(width: width, height: height)
    let widthConstraint = widthAnchor.constraint(equalToConstant: dimensions.width)
    let heightConstraint = heightAnchor.constraint(equalToConstant: dimensions.height)

    imageConstraints = [
      widthConstraint,
      heightConstraint,
      thumbnailView.topAnchor.constraint(equalTo: topAnchor),
      thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor),
      thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor),
      thumbnailView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]

    NSLayoutConstraint.activate(imageConstraints)
  }

  private func setupViews() {
    addSubview(thumbnailView)
    addSubview(overlayBackground)
    overlayBackground.addSubview(overlayIconView)
    overlayBackground.addSubview(overlaySpinner)
    overlayBackground.addSubview(downloadProgressView)
    overlayBackground.addSubview(cancelDownloadButton)
    addSubview(durationBadge)

    NSLayoutConstraint.activate([
      overlayBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
      overlayBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
      overlayBackground.widthAnchor.constraint(equalToConstant: 44),
      overlayBackground.heightAnchor.constraint(equalToConstant: 44),

      overlayIconView.centerXAnchor.constraint(equalTo: overlayBackground.centerXAnchor),
      overlayIconView.centerYAnchor.constraint(equalTo: overlayBackground.centerYAnchor),

      overlaySpinner.centerXAnchor.constraint(equalTo: overlayBackground.centerXAnchor),
      overlaySpinner.centerYAnchor.constraint(equalTo: overlayBackground.centerYAnchor),

      downloadProgressView.topAnchor.constraint(equalTo: overlayBackground.topAnchor, constant: 3),
      downloadProgressView.leadingAnchor.constraint(equalTo: overlayBackground.leadingAnchor, constant: 3),
      downloadProgressView.trailingAnchor.constraint(equalTo: overlayBackground.trailingAnchor, constant: -3),
      downloadProgressView.bottomAnchor.constraint(equalTo: overlayBackground.bottomAnchor, constant: -3),

      cancelDownloadButton.centerXAnchor.constraint(equalTo: overlayBackground.centerXAnchor),
      cancelDownloadButton.centerYAnchor.constraint(equalTo: overlayBackground.centerYAnchor),

      durationBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      durationBadge.topAnchor.constraint(equalTo: topAnchor, constant: 6),
    ])

    durationBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
    durationBadge.setContentHuggingPriority(.required, for: .horizontal)

    setupVideoConstraints()
    setupMask()
    setupGestures()
    updateImage()
    updateDurationLabel()
    updateOverlay()
  }

  private func setupGestures() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tapGesture.delegate = self
    addGestureRecognizer(tapGesture)
    cancelDownloadButton.addTarget(self, action: #selector(handleCancelDownload), for: .touchUpInside)
  }

  private func setupMask() {
    maskLayer.fillColor = UIColor.black.cgColor
    layer.mask = maskLayer
  }

  private func updateMask() {
    let roundingCorners: UIRectCorner = if !hasText, !hasReply, !hasReactionsInBubble {
      .allCorners
    } else if hasReactionsInBubble {
      [.topLeft, .topRight]
    } else if hasText, !hasReply {
      [.topLeft, .topRight]
    } else if hasReply, !hasText {
      [.bottomLeft, .bottomRight]
    } else {
      []
    }

    let viewBounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    let bezierPath = UIBezierPath(
      roundedRect: viewBounds,
      byRoundingCorners: roundingCorners,
      cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
    )

    maskLayer.path = bezierPath.cgPath
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateMask()
    overlayBackground.layer.cornerRadius = overlayBackground.bounds.height / 2
  }

  // MARK: - Public

  public func update(with fullMessage: FullMessage) {
    let prev = self.fullMessage
    self.fullMessage = fullMessage

    if
      prev.videoInfo?.id == fullMessage.videoInfo?.id,
      prev.videoInfo?.thumbnail?.bestPhotoSize()?.localPath
        == fullMessage.videoInfo?.thumbnail?.bestPhotoSize()?.localPath
    {
      updateOverlay()
      updateDurationLabel()
      return
    }

    progressCancellable?.cancel()
    progressCancellable = nil
    isDownloading = false
    downloadProgress = 0
    downloadProgressView.setProgress(0)

    setupVideoConstraints()
    updateImage()
    updateDurationLabel()
    updateOverlay()
  }

  // MARK: - Thumbnail Loading

  private func updateImage() {
    thumbnailView.setPhoto(fullMessage.videoInfo?.thumbnail, reloadMessageOnFinish: fullMessage.message)
  }

  // MARK: - Overlay

  private func updateOverlay() {
    let isVideoDownloaded = hasLocalVideoFile()
    let isUploading = fullMessage.message.status == .sending && fullMessage.videoInfo?.video.cdnUrl == nil
    let globalDownloadActive = fullMessage.videoInfo
      .map { FileDownloader.shared.isVideoDownloadActive(videoId: $0.id) } ?? false
    let downloading = !isVideoDownloaded && (isDownloading || globalDownloadActive)

    if isUploading {
      overlayIconView.isHidden = true
      overlaySpinner.startAnimating()
      downloadProgressView.isHidden = true
      cancelDownloadButton.isHidden = true
    } else if downloading {
      overlaySpinner.stopAnimating()
      overlayIconView.isHidden = true
      downloadProgressView.isHidden = false
      cancelDownloadButton.isHidden = false
      downloadProgressView.setProgress(downloadProgress)
      if let videoId = fullMessage.videoInfo?.id {
        bindProgressIfNeeded(videoId: videoId)
      }
    } else {
      overlaySpinner.stopAnimating()
      overlayIconView.isHidden = false
      downloadProgressView.isHidden = true
      cancelDownloadButton.isHidden = true
      overlayIconView.image = UIImage(
        systemName: isVideoDownloaded ? "play.fill" : "arrow.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
      )
    }

    overlayBackground.isHidden = false
  }

  private func updateDurationLabel() {
    guard let duration = fullMessage.videoInfo?.video.duration, duration > 0 else {
      durationBadge.isHidden = true
      return
    }

    durationBadge.isHidden = false
    durationBadge.text = formatDuration(seconds: duration)
  }

  private func formatDuration(seconds: Int) -> String {
    let mins = seconds / 60
    let secs = seconds % 60
    if mins >= 60 {
      let hours = mins / 60
      let remMins = mins % 60
      return String(format: "%d:%02d:%02d", hours, remMins, secs)
    }
    return String(format: "%d:%02d", mins, secs)
  }

  // MARK: - Playback

  @objc private func handleTap() {
    if let local = videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
      presentViewer(url: local)
      return
    }

    startDownloadIfNeeded()
  }

  private func presentViewer(url: URL) {
    guard let viewController = findViewController() else { return }
    guard !isPresentingViewer else { return }
    if viewController.presentedViewController != nil || viewController.isBeingPresented || viewController.isBeingDismissed {
      pendingViewerURL = url
      return
    }

    let controller = ImageViewerController(
      videoURL: url,
      sourceView: thumbnailView,
      sourceImage: snapshotThumbnail()
    )
    controller.onDismiss = { [weak self] in
      guard let self else { return }
      self.isPresentingViewer = false
      if let pending = self.pendingViewerURL {
        self.pendingViewerURL = nil
        DispatchQueue.main.async { [weak self] in
          self?.presentViewer(url: pending)
        }
      }
    }

    isPresentingViewer = true
    viewController.present(controller, animated: false)
  }

  private func startDownloadIfNeeded() {
    guard let videoInfo = fullMessage.videoInfo else { return }
    guard videoInfo.video.cdnUrl != nil else { return }

    if FileDownloader.shared.isVideoDownloadActive(videoId: videoInfo.id) {
      bindProgressIfNeeded(videoId: videoInfo.id)
      return
    }

    isDownloading = true
    downloadProgress = 0
    downloadProgressView.setProgress(0)
    updateOverlay()
    FileDownloader.shared.downloadVideo(video: videoInfo, for: fullMessage.message) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.isDownloading = false
        self.downloadProgress = 0
        self.updateOverlay()
      }
    }

    bindProgressIfNeeded(videoId: videoInfo.id)
  }

  private func bindProgressIfNeeded(videoId: Int64) {
    guard progressCancellable == nil else { return }

    progressCancellable = FileDownloader.shared.videoProgressPublisher(videoId: videoId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self else { return }

        if let local = self.videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
          self.progressCancellable = nil
          self.isDownloading = false
          self.downloadProgress = 0
          self.updateOverlay()
          return
        }

        if progress.error == nil, !progress.isComplete {
          self.downloadProgress = progress.progress
          self.downloadProgressView.setProgress(progress.progress)
        }

        if progress.error != nil || progress.isComplete {
          self.progressCancellable = nil
          self.isDownloading = false
          self.downloadProgress = 0
          self.updateOverlay()
        }
      }
  }

  @objc private func handleCancelDownload() {
    guard let videoId = fullMessage.videoInfo?.id else { return }
    FileDownloader.shared.cancelVideoDownload(videoId: videoId)
    progressCancellable?.cancel()
    progressCancellable = nil
    isDownloading = false
    downloadProgress = 0
    downloadProgressView.setProgress(0)
    updateOverlay()
  }

  private func videoLocalUrl() -> URL? {
    if let localPath = fullMessage.videoInfo?.video.localPath {
      return FileCache.getUrl(for: .videos, localPath: localPath)
    }
    return nil
  }

  private func hasLocalVideoFile() -> Bool {
    guard let local = videoLocalUrl() else { return false }
    return FileManager.default.fileExists(atPath: local.path)
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

  // MARK: - Snapshot

  private func snapshotThumbnail() -> UIImage? {
    guard thumbnailView.bounds.width > 0, thumbnailView.bounds.height > 0 else { return nil }
    let renderer = UIGraphicsImageRenderer(bounds: thumbnailView.bounds)
    return renderer.image { context in
      thumbnailView.layer.render(in: context.cgContext)
    }
  }
}

extension NewVideoView: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if let touchedView = touch.view, touchedView.isDescendant(of: cancelDownloadButton) {
      return false
    }
    return true
  }
}

import Combine
import GRDB
import InlineKit
import InlineUI
import Logger
import UIKit

final class NewVideoView: UIView {
  // MARK: - Properties

  private static let overlaySymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

  private static func overlaySymbolImage(named systemName: String) -> UIImage? {
    UIImage(systemName: systemName, withConfiguration: overlaySymbolConfiguration)?
      .withTintColor(.white, renderingMode: .alwaysOriginal)
  }

  private enum ActiveTransfer {
    case downloading(videoId: Int64)
    case uploading(videoLocalId: Int64, transactionId: String?, randomId: Int64?)
  }

  private var fullMessage: FullMessage
  private let maxWidth: CGFloat = 280
  private let maxHeight: CGFloat = 400
  private let minWidth: CGFloat = 180
  private let cornerRadius: CGFloat = 16.0
  private let maskLayer = CAShapeLayer()
  private var imageConstraints: [NSLayoutConstraint] = []
  private var downloadProgressCancellable: AnyCancellable?
  private var uploadProgressCancellable: AnyCancellable?
  private var uploadProgressBindingTask: Task<Void, Never>?
  private var uploadProgressLocalId: Int64?
  private var uploadProgressSnapshot: UploadProgressSnapshot?
  private var downloadProgressSnapshot: DownloadProgress?
  private var activeTransfer: ActiveTransfer?
  private var isDownloading = false
  private var isPresentingViewer = false
  private var pendingViewerURL: URL?
  private var downloadProgress: Double = 0
  private var resolvedVideoLocalPath: String?

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

  private let tinyThumbnailBackgroundView: InlineTinyThumbnailBackgroundView = {
    let view = InlineTinyThumbnailBackgroundView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let highlightOverlay: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = UIColor.white.withAlphaComponent(0.1)
    view.alpha = 0
    view.isUserInteractionEnabled = false
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
    let imageView = UIImageView(image: NewVideoView.overlaySymbolImage(named: "play.fill"))
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.tintColor = .white
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()

  private let transferProgressView: CircularProgressHostingView = {
    let view = CircularProgressHostingView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    return view
  }()

  private let cancelTransferButton: UIButton = {
    let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
    button.tintColor = .white
    button.isHidden = true
    button.accessibilityLabel = "Cancel transfer"
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
    resolvedVideoLocalPath = fullMessage.videoInfo?.video.localPath
    super.init(frame: .zero)

    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    downloadProgressCancellable?.cancel()
    uploadProgressCancellable?.cancel()
    uploadProgressBindingTask?.cancel()
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
    addSubview(tinyThumbnailBackgroundView)
    addSubview(thumbnailView)
    addSubview(highlightOverlay)
    addSubview(overlayBackground)
    overlayBackground.addSubview(overlayIconView)
    overlayBackground.addSubview(transferProgressView)
    overlayBackground.addSubview(cancelTransferButton)
    addSubview(durationBadge)

    NSLayoutConstraint.activate([
      tinyThumbnailBackgroundView.topAnchor.constraint(equalTo: topAnchor),
      tinyThumbnailBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tinyThumbnailBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tinyThumbnailBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      overlayBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
      overlayBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
      overlayBackground.widthAnchor.constraint(equalToConstant: 44),
      overlayBackground.heightAnchor.constraint(equalToConstant: 44),

      overlayIconView.centerXAnchor.constraint(equalTo: overlayBackground.centerXAnchor),
      overlayIconView.centerYAnchor.constraint(equalTo: overlayBackground.centerYAnchor),

      transferProgressView.topAnchor.constraint(equalTo: overlayBackground.topAnchor, constant: 3),
      transferProgressView.leadingAnchor.constraint(equalTo: overlayBackground.leadingAnchor, constant: 3),
      transferProgressView.trailingAnchor.constraint(equalTo: overlayBackground.trailingAnchor, constant: -3),
      transferProgressView.bottomAnchor.constraint(equalTo: overlayBackground.bottomAnchor, constant: -3),

      cancelTransferButton.centerXAnchor.constraint(equalTo: overlayBackground.centerXAnchor),
      cancelTransferButton.centerYAnchor.constraint(equalTo: overlayBackground.centerYAnchor),

      durationBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      durationBadge.topAnchor.constraint(equalTo: topAnchor, constant: 6),

      highlightOverlay.topAnchor.constraint(equalTo: topAnchor),
      highlightOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
      highlightOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
      highlightOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    durationBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
    durationBadge.setContentHuggingPriority(.required, for: .horizontal)

    setupVideoConstraints()
    setupMask()
    setupGestures()
    updateTinyThumbnailBackground()
    updateImage()
    syncUploadProgressBinding()
    updateDurationLabel()
    updateOverlay()
  }

  private func setupGestures() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tapGesture.delegate = self
    addGestureRecognizer(tapGesture)
    cancelTransferButton.addTarget(self, action: #selector(handleCancelTransfer), for: .touchUpInside)
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
    if prev.videoInfo?.id != fullMessage.videoInfo?.id {
      resolvedVideoLocalPath = fullMessage.videoInfo?.video.localPath
    } else if let localPath = fullMessage.videoInfo?.video.localPath {
      resolvedVideoLocalPath = localPath
    }
    updateMask()
    updateTinyThumbnailBackground()
    syncUploadProgressBinding()

    if
      prev.videoInfo?.id == fullMessage.videoInfo?.id,
      prev.videoInfo?.thumbnail?.bestPhotoSize()?.localPath
        == fullMessage.videoInfo?.thumbnail?.bestPhotoSize()?.localPath
    {
      updateOverlay()
      updateDurationLabel()
      return
    }

    downloadProgressCancellable?.cancel()
    downloadProgressCancellable = nil
    isDownloading = false
    downloadProgressSnapshot = nil
    downloadProgress = 0
    transferProgressView.setProgress(0)
    activeTransfer = nil

    setupVideoConstraints()
    updateImage()
    updateDurationLabel()
    updateOverlay()
  }

  // MARK: - Thumbnail Loading

  private func updateImage() {
    thumbnailView.setPhoto(fullMessage.videoInfo?.thumbnail, reloadMessageOnFinish: fullMessage.message)
  }

  private func updateTinyThumbnailBackground() {
    tinyThumbnailBackgroundView.setPhoto(fullMessage.videoInfo?.thumbnail)
  }

  // MARK: - Overlay

  private func updateOverlay() {
    let isVideoDownloaded = hasLocalVideoFile()
    if isVideoDownloaded {
      downloadProgressCancellable?.cancel()
      downloadProgressCancellable = nil
      isDownloading = false
      downloadProgressSnapshot = nil
      downloadProgress = 0
    }

    let isUploading = isPendingUpload()
      || uploadProgressSnapshot?.stage == .processing
      || uploadProgressSnapshot?.stage == .uploading
    let globalDownloadActive = fullMessage.videoInfo
      .map { FileDownloader.shared.isVideoDownloadActive(videoId: $0.id) } ?? false
    let downloading = !isVideoDownloaded && (isDownloading || globalDownloadActive)

    if isUploading {
      let uploadProgress = max(0, min(uploadProgressSnapshot?.fractionCompleted ?? 0, 1))
      overlayIconView.isHidden = true
      transferProgressView.isHidden = false
      cancelTransferButton.isHidden = false
      transferProgressView.setProgress(uploadProgress)
      if let videoLocalId = fullMessage.videoInfo?.video.id {
        activeTransfer = .uploading(
          videoLocalId: videoLocalId,
          transactionId: fullMessage.message.transactionId,
          randomId: fullMessage.message.randomId
        )
      } else {
        activeTransfer = nil
      }
    } else if downloading {
      overlayIconView.isHidden = true
      transferProgressView.isHidden = false
      cancelTransferButton.isHidden = false
      transferProgressView.setProgress(downloadProgress)
      if let videoId = fullMessage.videoInfo?.id {
        activeTransfer = .downloading(videoId: videoId)
      } else {
        activeTransfer = nil
      }
      if let videoId = fullMessage.videoInfo?.id {
        bindProgressIfNeeded(videoId: videoId)
      }
    } else {
      overlayIconView.image = Self.overlaySymbolImage(named: isVideoDownloaded ? "play.fill" : "arrow.down")
      overlayIconView.isHidden = false
      transferProgressView.isHidden = true
      cancelTransferButton.isHidden = true
      activeTransfer = nil
    }

    overlayBackground.isHidden = false
  }

  private func updateDurationLabel() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.updateDurationLabel()
      }
      return
    }

    if isPendingUpload(), let uploadProgressSnapshot {
      durationBadge.isHidden = false
      switch uploadProgressSnapshot.stage {
      case .processing:
        durationBadge.text = "Processing"
      case .uploading, .completed:
        durationBadge.text = uploadProgressLabel(uploadProgressSnapshot)
      case .failed:
        durationBadge.text = "Failed"
      }
      return
    }

    if isDownloadInFlight(), let downloadProgressSnapshot = currentDownloadProgressSnapshot() {
      durationBadge.isHidden = false
      durationBadge.text = downloadProgressLabel(downloadProgressSnapshot)
      return
    }

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

  private func uploadProgressLabel(_ progress: UploadProgressSnapshot) -> String {
    if progress.totalBytes > 0 {
      return "\(formatTransferBytes(progress.bytesSent))/\(formatTransferBytes(progress.totalBytes))"
    }

    if progress.fractionCompleted > 0 {
      let percent = Int((progress.fractionCompleted * 100).rounded())
      return "\(percent)%"
    }

    return "Uploading"
  }

  private func downloadProgressLabel(_ progress: DownloadProgress) -> String {
    let totalBytes = progress.totalBytes > 0 ? progress.totalBytes : Int64(fullMessage.videoInfo?.video.size ?? 0)
    if totalBytes > 0 {
      return "\(formatTransferBytes(progress.bytesReceived))/\(formatTransferBytes(totalBytes))"
    }

    if progress.progress > 0 {
      let percent = Int((progress.progress * 100).rounded())
      return "\(percent)%"
    }

    return "Downloading"
  }

  private func formatTransferBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
  }

  private func isPendingUpload() -> Bool {
    fullMessage.message.status == .sending && fullMessage.videoInfo?.video.cdnUrl == nil
  }

  private func isDownloadInFlight() -> Bool {
    guard !hasLocalVideoFile() else { return false }
    let globalDownloadActive = fullMessage.videoInfo
      .map { FileDownloader.shared.isVideoDownloadActive(videoId: $0.id) } ?? false
    return isDownloading || globalDownloadActive
  }

  private func currentDownloadProgressSnapshot() -> DownloadProgress? {
    if let downloadProgressSnapshot {
      return downloadProgressSnapshot
    }

    guard let videoId = fullMessage.videoInfo?.id else { return nil }
    let totalBytes = Int64(fullMessage.videoInfo?.video.size ?? 0)
    return DownloadProgress(id: "video_\(videoId)", bytesReceived: 0, totalBytes: totalBytes)
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
    downloadProgressSnapshot = currentDownloadProgressSnapshot()
    downloadProgress = 0
    transferProgressView.setProgress(0)
    updateDurationLabel()
    updateOverlay()
    FileDownloader.shared.downloadVideo(video: videoInfo, for: fullMessage.message) { [weak self] result in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if case .failure = result {
          self.isDownloading = false
          self.downloadProgressSnapshot = nil
          self.downloadProgress = 0
          self.updateDurationLabel()
          self.updateOverlay()
          return
        }

        if let local = self.videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
          self.isDownloading = false
          self.downloadProgressSnapshot = nil
          self.downloadProgress = 0
          self.updateDurationLabel()
        }
        self.updateOverlay()
      }
    }

    bindProgressIfNeeded(videoId: videoInfo.id)
  }

  private func bindProgressIfNeeded(videoId: Int64) {
    guard downloadProgressCancellable == nil else { return }

    if downloadProgressSnapshot == nil {
      downloadProgressSnapshot = currentDownloadProgressSnapshot()
      updateDurationLabel()
    }

    downloadProgressCancellable = FileDownloader.shared.videoProgressPublisher(videoId: videoId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self else { return }

        if let local = self.videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
          self.downloadProgressCancellable = nil
          self.isDownloading = false
          self.downloadProgressSnapshot = nil
          self.downloadProgress = 0
          self.activeTransfer = nil
          self.updateDurationLabel()
          self.updateOverlay()
          return
        }

        if progress.error == nil {
          self.downloadProgressSnapshot = progress
          self.downloadProgress = progress.progress
          self.transferProgressView.setProgress(progress.progress)
          self.updateDurationLabel()
        }

        if progress.error != nil {
          self.downloadProgressCancellable = nil
          self.isDownloading = false
          self.downloadProgressSnapshot = nil
          self.downloadProgress = 0
          self.activeTransfer = nil
          self.updateDurationLabel()
          self.updateOverlay()
        }
      }
  }

  @objc private func handleCancelTransfer() {
    guard let activeTransfer else { return }

    switch activeTransfer {
    case let .downloading(videoId):
      FileDownloader.shared.cancelVideoDownload(videoId: videoId)
      downloadProgressCancellable?.cancel()
      downloadProgressCancellable = nil
      isDownloading = false
      downloadProgressSnapshot = nil
      downloadProgress = 0
      transferProgressView.setProgress(0)
      self.activeTransfer = nil
      updateDurationLabel()
      updateOverlay()

    case let .uploading(videoLocalId, transactionId, randomId):
      Task {
        await FileUploader.shared.cancelVideoUpload(videoLocalId: videoLocalId)
      }

      if let transactionId, !transactionId.isEmpty {
        Transactions.shared.cancel(transactionId: transactionId)
      } else if let randomId {
        Task {
          Api.realtime.cancelTransaction(where: {
            guard $0.transaction.method == .sendMessage else { return false }
            guard case let .sendMessage(input) = $0.transaction.input else { return false }
            return input.randomID == randomId
          })
        }
      }

      let message = fullMessage.message
      Task(priority: .userInitiated) {
        do {
          try await AppDatabase.shared.dbWriter.write { db in
            try Message.deleteMessages(db, messageIds: [message.messageId], chatId: message.chatId)
          }

          MessagesPublisher.shared
            .messagesDeleted(messageIds: [message.messageId], peer: message.peerId)
        } catch {
          Log.shared.error("Failed to delete local video message after cancellation", error: error)
        }
      }

      clearUploadProgressBinding(resetState: true)
      transferProgressView.setProgress(0)
      self.activeTransfer = nil
      updateOverlay()
    }
  }

  private func syncUploadProgressBinding() {
    guard isPendingUpload(), let videoLocalId = fullMessage.videoInfo?.video.id else {
      clearUploadProgressBinding(resetState: true)
      return
    }

    if uploadProgressLocalId == videoLocalId, (uploadProgressCancellable != nil || uploadProgressBindingTask != nil) {
      return
    }

    clearUploadProgressBinding(resetState: false)
    uploadProgressLocalId = videoLocalId
    uploadProgressBindingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let publisher = await FileUploader.shared.videoProgressPublisher(videoLocalId: videoLocalId)
      guard !Task.isCancelled, self.uploadProgressLocalId == videoLocalId else { return }

      self.uploadProgressBindingTask = nil
      self.uploadProgressCancellable = publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] progress in
          guard let self else { return }
          self.uploadProgressSnapshot = progress
          self.updateDurationLabel()
          self.updateOverlay()
        }
    }
  }

  private func clearUploadProgressBinding(resetState: Bool) {
    uploadProgressBindingTask?.cancel()
    uploadProgressBindingTask = nil
    uploadProgressCancellable?.cancel()
    uploadProgressCancellable = nil
    uploadProgressLocalId = nil
    if resetState {
      uploadProgressSnapshot = nil
    }
  }

  private func videoLocalUrl() -> URL? {
    if let localPath = fullMessage.videoInfo?.video.localPath ?? resolvedVideoLocalPath {
      return FileCache.getUrl(for: .videos, localPath: localPath)
    }

    guard let videoId = fullMessage.videoInfo?.video.id else { return nil }
    if let latestLocalPath = try? AppDatabase.shared.reader.read({ db in
      try Video.filter(Video.Columns.id == videoId).fetchOne(db)?.localPath
    }) {
      resolvedVideoLocalPath = latestLocalPath
      return FileCache.getUrl(for: .videos, localPath: latestLocalPath)
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

  // MARK: - Highlight

  func showHighlight() {
    highlightOverlay.layer.removeAllAnimations()
    highlightOverlay.alpha = 0
    UIView.animate(withDuration: 0.18, animations: { [weak self] in
      self?.highlightOverlay.alpha = 1
    }) { [weak self] _ in
      guard let self else { return }
      UIView.animate(withDuration: 0.5, delay: 0.2, options: [], animations: {
        self.highlightOverlay.alpha = 0
      }, completion: nil)
    }
  }

  func clearHighlight() {
    highlightOverlay.layer.removeAllAnimations()
    highlightOverlay.alpha = 0
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
    if let touchedView = touch.view, touchedView.isDescendant(of: cancelTransferButton) {
      return false
    }
    return true
  }
}

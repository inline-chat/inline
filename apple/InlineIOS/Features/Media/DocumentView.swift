import Combine
import Foundation
import GRDB
import InlineKit
import InlineUI
import Logger
import QuickLook
import UIKit

class DocumentView: UIView, UIGestureRecognizerDelegate {
  // MARK: - Properties

  private var fullMessage: FullMessage?
  private var outgoing: Bool
  private var isBeingRemoved = false
  private static let log = Log.scoped("DocumentView", level: .info)

  enum DocumentState: Equatable {
    case uploadFailed
    case locallyAvailable
    case needsDownload
    case downloading(bytesReceived: Int64, totalBytes: Int64)
    case uploading(bytesSent: Int64, totalBytes: Int64)
  }

  private var progressSubscription: AnyCancellable?
  private var uploadProgressSubscription: AnyCancellable?
  private var uploadProgressBindingTask: Task<Void, Never>?
  private var uploadProgressLocalId: Int64?
  private var uploadProgressSnapshot: UploadProgressSnapshot?
  private var isUploadProcessing = false
  private var documentState: DocumentState = .needsDownload {
    didSet {
      updateUIForDocumentState()
    }
  }

  private var previewController: QLPreviewController?
  private var documentInteractionController: UIDocumentInteractionController?
  private var documentURL: URL?
  private weak var viewTapGesture: UITapGestureRecognizer?

  // Progress border
  private let progressLayer = CAShapeLayer()

  var documentInfo: DocumentInfo? {
    fullMessage?.documentInfo
  }

  var document: Document? {
    documentInfo?.document
  }

  private var hasDocumentThumbnail: Bool {
    documentInfo?.thumbnail?.hasDisplayablePreview == true
  }

  var textColor: UIColor {
    outgoing ? .white : ThemeManager.shared.selected.primaryTextColor ?? .label
  }

  var labelColor: UIColor {
    outgoing ? .white.withAlphaComponent(0.4) : ThemeManager.shared.selected.secondaryTextColor ?? .label
      .withAlphaComponent(0.4)
  }

  var fileIconWrapperColor: UIColor {
    outgoing ? .white.withAlphaComponent(0.2) : ThemeManager.shared.selected.documentIconBackground ?? .systemGray5
      .withAlphaComponent(0.2)
  }

  var progressBarColor: UIColor {
    outgoing ? .white : ThemeManager.shared.selected.accent
  }

  // MARK: - Initializers

  init(fullMessage: FullMessage?, outgoing: Bool) {
    self.fullMessage = fullMessage
    self.outgoing = outgoing

    super.init(frame: .zero)

    setupViews()
    setupContent()
    setupProgressLayer()

    if let document {
      documentState = determineDocumentState(document)
    }

    syncUploadProgressBinding()

    updateUIForDocumentState()

    // Listen for upload notifications
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDocumentUploadStarted(_:)),
      name: NSNotification.Name("DocumentUploadStarted"),
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDocumentUploadCompleted(_:)),
      name: NSNotification.Name("DocumentUploadCompleted"),
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDocumentUploadFailed(_:)),
      name: NSNotification.Name("DocumentUploadFailed"),
      object: nil
    )

    // Listen for message status changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMessageStatusChanged(_:)),
      name: NSNotification.Name("MessageStatusChanged"),
      object: nil
    )

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
    tapGesture.delegate = self
    addGestureRecognizer(tapGesture)
    viewTapGesture = tapGesture
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Views

  let horizantalStackView = createHorizantalStackView()
  let textsStackView = createTextsStackView()
  let fileIconButton = createFileIconButton()
  let thumbnailView = createThumbnailView()
  let thumbnailTransferOverlay = createThumbnailTransferOverlay()
  let iconView = createFileIcon()
  let verticalStackView = createVerticalStackView()
  let fileNameLabel = createFileNameLabel()
  let fileSizeLabel = createFileSizeLabel()
  private var mediaWidthConstraint: NSLayoutConstraint!
  private var mediaHeightConstraint: NSLayoutConstraint!

  // MARK: - Setup & helpers

  /// Height of this view as its stacks lay it out: the 38 pt icon below a 2 pt top inset.
  static let preferredHeight: CGFloat = 40

  /// Width of this view for a file, as its stacks lay it out; the next message view plans with
  /// it. The size label reserves one and a half times its text, as `setupContent` does.
  static func preferredWidth(fileName: String?, size: Int?) -> CGFloat {
    let name = (fileName ?? "Unknown File") as NSString
    let sizeText = FileHelpers.formatFileSize(UInt64(size ?? 0)) as NSString
    let nameWidth = name.size(withAttributes: [.font: UIFont.systemFont(ofSize: 15)]).width
    let sizeWidth = sizeText.size(withAttributes: [.font: UIFont.systemFont(ofSize: 13)]).width * 1.5
    return ceil(38 + 8 + max(nameWidth, sizeWidth) + 4)
  }

  override var intrinsicContentSize: CGSize {
    let targetSize = CGSize(
      width: UIView.layoutFittingCompressedSize.width,
      height: UIView.layoutFittingCompressedSize.height
    )
    let stackSize = horizantalStackView.systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: .fittingSizeLevel,
      verticalFittingPriority: .fittingSizeLevel
    )
    return CGSize(width: ceil(stackSize.width + 4), height: ceil(stackSize.height + 2))
  }

  func setupViews() {
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)

    addSubview(horizantalStackView)
    horizantalStackView.addArrangedSubview(fileIconButton)
    fileIconButton.addSubview(thumbnailView)
    fileIconButton.addSubview(thumbnailTransferOverlay)
    fileIconButton.addSubview(iconView)
    horizantalStackView.addArrangedSubview(verticalStackView)
    verticalStackView.addArrangedSubview(fileNameLabel)
    verticalStackView.addArrangedSubview(fileSizeLabel)

    mediaWidthConstraint = fileIconButton.widthAnchor.constraint(equalToConstant: 38)
    mediaHeightConstraint = fileIconButton.heightAnchor.constraint(equalToConstant: 38)

    NSLayoutConstraint.activate([
      horizantalStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      horizantalStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      horizantalStackView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      horizantalStackView.bottomAnchor.constraint(equalTo: bottomAnchor),

      mediaWidthConstraint,
      mediaHeightConstraint,

      thumbnailView.leadingAnchor.constraint(equalTo: fileIconButton.leadingAnchor),
      thumbnailView.trailingAnchor.constraint(equalTo: fileIconButton.trailingAnchor),
      thumbnailView.topAnchor.constraint(equalTo: fileIconButton.topAnchor),
      thumbnailView.bottomAnchor.constraint(equalTo: fileIconButton.bottomAnchor),

      thumbnailTransferOverlay.centerXAnchor.constraint(equalTo: fileIconButton.centerXAnchor),
      thumbnailTransferOverlay.centerYAnchor.constraint(equalTo: fileIconButton.centerYAnchor),
      thumbnailTransferOverlay.widthAnchor.constraint(equalToConstant: 38),
      thumbnailTransferOverlay.heightAnchor.constraint(equalToConstant: 38),

      iconView.centerXAnchor.constraint(equalTo: fileIconButton.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: fileIconButton.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 22),
      iconView.heightAnchor.constraint(equalToConstant: 22),
    ])

    fileIconButton.addTarget(self, action: #selector(fileIconButtonTapped), for: .touchUpInside)
  }

  private func setupProgressLayer() {
    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.strokeColor = progressBarColor.cgColor
    progressLayer.lineWidth = 2
    progressLayer.lineCap = .round
    // A full circle starting at the top; strokeEnd reveals how much of it is drawn.
    progressLayer.path = UIBezierPath(
      arcCenter: CGPoint(x: 19, y: 19),
      radius: 18,
      startAngle: -CGFloat.pi / 2,
      endAngle: 3 * CGFloat.pi / 2,
      clockwise: true
    ).cgPath
    progressLayer.strokeEnd = 0

    fileIconButton.layer.addSublayer(progressLayer)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let progressSize: CGFloat = 38
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progressLayer.frame = CGRect(
      x: floor((fileIconButton.bounds.width - progressSize) / 2),
      y: floor((fileIconButton.bounds.height - progressSize) / 2),
      width: progressSize,
      height: progressSize
    )
    CATransaction.commit()
  }

  /// Short arc kept visible before the first bytes arrive, so a starting download never looks stalled.
  private static let minimumDownloadArc: CGFloat = 0.06

  /// Fills the ring with download progress while it spins, as other messengers do.
  private func showDownloadProgress(_ progress: CGFloat) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.25)
    progressLayer.strokeEnd = min(1, max(progress, Self.minimumDownloadArc))
    CATransaction.commit()
    startProgressRotation()
  }

  private func showUploadingSpinner() {
    // A 1/9 arc (40 degrees) spinning until the upload reports completion.
    setProgressStrokeEnd(1 / 9)
    startProgressRotation()
  }

  private func hideProgressRing() {
    progressLayer.removeAnimation(forKey: "rotation")
    setProgressStrokeEnd(0)
  }

  private func setProgressStrokeEnd(_ strokeEnd: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progressLayer.strokeEnd = strokeEnd
    CATransaction.commit()
  }

  private func startProgressRotation() {
    guard progressLayer.animation(forKey: "rotation") == nil else { return }

    let rotation = CABasicAnimation(keyPath: "transform.rotation")
    rotation.fromValue = 0
    rotation.toValue = 2 * CGFloat.pi
    rotation.duration = 1.5
    rotation.repeatCount = .infinity
    rotation.isRemovedOnCompletion = false
    progressLayer.add(rotation, forKey: "rotation")
  }

  private var fileSizeMinWidthConstraint: NSLayoutConstraint?

  func setupContent() {
    // Colors
    fileNameLabel.textColor = textColor
    fileSizeLabel.textColor = labelColor
    configureThumbnail()

    // Data
    fileNameLabel.text = document?.fileName ?? "Unknown File"
    fileSizeLabel.text = FileHelpers.formatFileSize(UInt64(document?.size ?? 0))

    // Set fixed width for fileSizeLabel to prevent layout shifts
    let maxSizeTextWidth = fileSizeLabel.intrinsicContentSize.width * 1.5
    if let fileSizeMinWidthConstraint {
      fileSizeMinWidthConstraint.constant = maxSizeTextWidth
    } else {
      let constraint = fileSizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: maxSizeTextWidth)
      constraint.isActive = true
      fileSizeMinWidthConstraint = constraint
    }

    updateFileIcon()
    invalidateIntrinsicContentSize()
  }

  private func configureThumbnail() {
    let hasThumbnail = hasDocumentThumbnail
    let mediaSize: CGFloat = hasThumbnail ? 70 : 38
    mediaWidthConstraint.constant = mediaSize
    mediaHeightConstraint.constant = mediaSize
    fileIconButton.layer.cornerRadius = hasThumbnail ? 8 : 19
    fileIconButton.backgroundColor = hasThumbnail ? .clear : fileIconWrapperColor
    thumbnailView.isHidden = !hasThumbnail
    thumbnailView.setPhoto(
      hasThumbnail ? documentInfo?.thumbnail : nil,
      reloadMessageOnFinish: fullMessage?.message
    )
  }

  func update(with fullMessage: FullMessage, outgoing: Bool) {
    self.fullMessage = fullMessage
    self.outgoing = outgoing
    isBeingRemoved = false
    progressSubscription?.cancel()
    progressSubscription = nil
    clearUploadProgressBinding(resetState: true)

    setupContent()

    if let document {
      documentState = determineDocumentState(document)
    } else {
      documentState = .needsDownload
    }

    syncUploadProgressBinding()
    if superview != nil, case .downloading = documentState {
      // A rebind cancels the subscription above; keep following the transfer still in flight.
      startMonitoringProgress()
    }

    updateUIForDocumentState()
    invalidateIntrinsicContentSize()
  }

  @objc func fileIconButtonTapped() {
    switch documentState {
      case .uploadFailed:
        resendFailedDocument()
      case .needsDownload:
        downloadFile()
      case .downloading:
        cancelDownload()
      case .uploading:
        cancelUpload()
      case .locallyAvailable:
        openFile()
    }
  }

  @objc func viewTapped() {
    // Prevent interactions if view is being removed
    guard !isBeingRemoved else { return }

    switch documentState {
      case .uploadFailed:
        resendFailedDocument()
      case .locallyAvailable:
        openFile()
      case .uploading:
        cancelUpload()
      case .downloading:
        cancelDownload()
      case .needsDownload:
        downloadFile()
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard gestureRecognizer === viewTapGesture else { return true }

    var touchedView: UIView? = touch.view
    while let view = touchedView, view !== self {
      if view is UIControl {
        return false
      }
      touchedView = view.superview
    }

    return true
  }

  private func updateFileIcon() {
    iconView.isHidden = hasDocumentThumbnail && documentState == .locallyAvailable
    thumbnailTransferOverlay.isHidden = !hasDocumentThumbnail || documentState == .locallyAvailable
    let thumbnailOverlayColor: UIColor = hasDocumentThumbnail ? .white : (outgoing ? .white : .systemGray)

    switch documentState {
      case .uploadFailed:
        iconView.image = UIImage(systemName: "exclamationmark.circle")
        iconView.tintColor = thumbnailOverlayColor
      case .needsDownload:
        iconView.image = UIImage(systemName: "arrow.down")
        iconView.tintColor = hasDocumentThumbnail ? .white : (outgoing ? .white : ThemeManager.shared.selected.accent)

      case .downloading:
        iconView.image = UIImage(systemName: "xmark")
        iconView.tintColor = hasDocumentThumbnail ? .white : (outgoing ? .white : ThemeManager.shared.selected.accent)

      case .uploading:
        iconView.image = UIImage(systemName: "xmark")
        iconView.tintColor = hasDocumentThumbnail ? .white : (outgoing ? .white : ThemeManager.shared.selected.accent)

      case .locallyAvailable:
        let iconName = DocumentIconResolver.symbolName(
          mimeType: document?.mimeType,
          fileName: document?.fileName,
          style: .filled
        )
        iconView.image = UIImage(systemName: iconName)
        iconView.tintColor = thumbnailOverlayColor
    }
  }

  private func updateUIForDocumentState() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.updateUIForDocumentState()
      }
      return
    }

    UIView.performWithoutAnimation {
      switch documentState {
        case .uploadFailed:
          hideProgressRing()
          fileSizeLabel.text = "Failed to send"
        case .locallyAvailable:
          hideProgressRing()
          fileSizeLabel.text = FileHelpers.formatFileSize(UInt64(document?.size ?? 0))

        case .needsDownload:
          hideProgressRing()
          fileSizeLabel.text = FileHelpers.formatFileSize(UInt64(document?.size ?? 0))

        case let .downloading(bytesReceived, totalBytes):
          let progress = totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : 0
          showDownloadProgress(CGFloat(progress))

          let downloadedStr = FileHelpers.formatFileSize(UInt64(bytesReceived))
          let totalStr = FileHelpers.formatFileSize(UInt64(totalBytes))
          fileSizeLabel.text = "\(downloadedStr) / \(totalStr)"

        case let .uploading(bytesSent, totalBytes):
          showUploadingSpinner()
          if let retryDescription = uploadProgressSnapshot?.pendingRetryDescription {
            fileSizeLabel.text = retryDescription
          } else if isUploadProcessing {
            fileSizeLabel.text = "processing..."
          } else if bytesSent == 0 {
            fileSizeLabel.text = "uploading..."
          } else {
            let uploadedStr = FileHelpers.formatFileSize(UInt64(bytesSent))
            let totalStr = FileHelpers.formatFileSize(UInt64(totalBytes))
            fileSizeLabel.text = "\(uploadedStr) / \(totalStr)"
          }
      }
    }

    updateFileIcon()
    updateProgressLayerColor()
    invalidateIntrinsicContentSize()
  }

  private func updateProgressLayerColor() {
    progressLayer.strokeColor = progressBarColor.cgColor
  }

  func downloadFile() {
    guard let documentInfo, let document, let fullMessage else {
      return
    }

    if case .downloading = documentState {
      return
    }

    documentState = .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))

    startMonitoringProgress()

    let startedNativeDownload = ExperimentalFeatureFlags.nativeFileDownloadsEnabled
    FileDownloader.shared.downloadDocument(document: documentInfo, for: fullMessage.message) { [weak self] result in
      guard let self else { return }

      DispatchQueue.main.async {
        guard self.documentInfo?.id == documentInfo.id else { return }
        switch result {
          case .success:
            self.documentState = .locallyAvailable
            self.progressSubscription?.cancel()
            self.progressSubscription = nil

          case let .failure(error):
            Self.log.error("Document download failed:", error: error)
            self.documentState = .needsDownload
            self.progressSubscription?.cancel()
            self.progressSubscription = nil
            if !FileDownloader.isCancellation(error), startedNativeDownload {
              ToastManager.shared.showToast(
                "File download failed",
                description: "Please try again.",
                type: .error,
                systemImage: "exclamationmark.triangle.fill"
              )
            }
        }
      }
    }
  }

  func cancelDownload() {
    if case .downloading = documentState {
      if let documentInfo {
        FileDownloader.shared.cancelDocumentDownload(documentId: documentInfo.id)
        guard !FileDownloader.shared.isDocumentDownloadActive(documentId: documentInfo.id) else { return }
      }

      documentState = .needsDownload

      progressSubscription?.cancel()
      progressSubscription = nil
    }
  }

  func cancelUpload() {
    guard case .uploading = documentState, let fullMessage,
          PendingMessageCanceller.cancel(fullMessage) else { return }
    isBeingRemoved = true
    hideProgressRing()
    clearUploadProgressBinding(resetState: true)
  }

  func openFile() {
    Self.log.trace("📄 openFile() called")

    guard
      let document,
      let localPath = document.localPath
    else {
      Self.log.error(
          "📄 Cannot open document: No local path available - document: \(document?.fileName ?? "nil"), localPath: \(document?.localPath ?? "nil")"
        )
      return
    }

    Self.log.trace(
        "📄 Document details - fileName: \(document.fileName ?? "unknown"), localPath: \(localPath), size: \(document.size ?? 0)"
      )

    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    let fileURL = cacheDirectory.appendingPathComponent(localPath)

    Self.log.trace("📄 Full file path: \(fileURL.path)")
    Self.log.trace("📄 Cache directory: \(cacheDirectory.path)")

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      Self.log.error("📄 File does not exist at path: \(fileURL.path)")
      Self.log.trace("📄 Directory contents: \(try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path))")
      documentState = .needsDownload
      return
    }

    // Get file attributes for debugging
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      Self.log.trace("📄 File attributes: \(attributes)")
    } catch {
      Self.log.error("📄 Failed to get file attributes: \(error)")
    }

    documentURL = fileURL

    // Check file extension to avoid QuickLook for problematic file types
    let fileExtension = fileURL.pathExtension.lowercased()
    let problematicExtensions = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx"]

    if problematicExtensions.contains(fileExtension) {
      Self.log.trace("📄 File type .\(fileExtension) may cause QuickLook crashes - using UIDocumentInteractionController")
      openWithDocumentInteraction(fileURL: fileURL)
      return
    }

    Self.log.trace("📄 About to check QLPreviewController.canPreview for: \(fileURL)")

    // Check if QuickLook can preview this file
    let canPreview = QLPreviewController.canPreview(fileURL as QLPreviewItem)
    Self.log.trace("📄 QLPreviewController.canPreview result: \(canPreview)")

    if canPreview {
      Self.log.trace("📄 Using QuickLook for preview")
      openWithQuickLook(fileURL: fileURL)
    } else {
      Self.log.trace("📄 QuickLook can't preview, using UIDocumentInteractionController")
      openWithDocumentInteraction(fileURL: fileURL)
    }
  }

  func resendFailedDocument() {
    guard let fullMessage else { return }
    Task { @MainActor in
      do { try await FailedMessageResender.resend(fullMessage) }
      catch { ToastManager.shared.showToast(error.localizedDescription, type: .error) }
    }
  }

  private func openWithQuickLook(fileURL: URL) {
    Self.log.trace("📄 openWithQuickLook() called for: \(fileURL)")

    let previewController = QLPreviewController()
    previewController.dataSource = self
    previewController.delegate = self
    self.previewController = previewController

    guard let viewController = findViewController() else {
      Self.log.error("📄 Cannot find view controller to present QuickLook preview")
      Self.log.trace("📄 Falling back to document interaction")
      openWithDocumentInteraction(fileURL: fileURL)
      return
    }

    Self.log.trace("📄 Found view controller: \(type(of: viewController))")
    Self.log.trace("📄 About to present QLPreviewController")

    DispatchQueue.main.async {
      Self.log.trace("📄 Presenting QLPreviewController on main thread")
      viewController.present(previewController, animated: true) {
        Self.log.trace("📄 QLPreviewController presentation completed")
      }
    }
  }

  private func openWithDocumentInteraction(fileURL: URL) {
    let documentInteractionController = UIDocumentInteractionController(url: fileURL)
    documentInteractionController.delegate = self
    self.documentInteractionController = documentInteractionController

    guard let viewController = findViewController() else {
      Self.log.error("Cannot find view controller to present document interaction")
      return
    }

    // Try to present preview first
    if documentInteractionController.presentPreview(animated: true) {
      Self.log.trace("Presented document preview using UIDocumentInteractionController")
    } else {
      // If preview fails, show options menu
      let rect = bounds
      if documentInteractionController.presentOptionsMenu(from: rect, in: self, animated: true) {
        Self.log.trace("Presented document options menu using UIDocumentInteractionController")
      } else {
        Self.log.error("Failed to present document using UIDocumentInteractionController")
        showDocumentError()
      }
    }
  }

  private func showDocumentError() {
    guard let viewController = findViewController() else { return }

    let alert = UIAlertController(
      title: "Cannot Open Document",
      message: "This document type is not supported for preview.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    viewController.present(alert, animated: true)
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

  // MARK: - Upload Management

  func startUpload() {
    guard let document else { return }

    isUploadProcessing = false
    let fileSize = Int64(document.size ?? 0)
    if let documentLocalId = document.id {
      uploadProgressSnapshot = .processing(id: "document_\(documentLocalId)")
    }
    documentState = .uploading(bytesSent: 0, totalBytes: fileSize)

    syncUploadProgressBinding()
  }

  // Public method to be called when document upload begins
  public func setUploadingState() {
    startUpload()
  }

  func updateUploadProgress(bytesSent: Int64, totalBytes: Int64) {
    documentState = .uploading(bytesSent: bytesSent, totalBytes: totalBytes)
  }

  func completeUpload() {
    isUploadProcessing = false
    hideProgressRing()
    if let document { documentState = determineDocumentState(document) }
    clearUploadProgressBinding(resetState: false)
  }

  func failUpload() {
    isUploadProcessing = false
    hideProgressRing()
    if let document { documentState = determineDocumentState(document) }
    clearUploadProgressBinding(resetState: false)
  }

  private func syncUploadProgressBinding() {
    guard isPendingOutgoingUploadMessage(), let document, let localDocumentId = document.id else {
      clearUploadProgressBinding(resetState: true)
      return
    }

    if uploadProgressLocalId == localDocumentId,
       uploadProgressBindingTask != nil || uploadProgressSubscription != nil
    {
      return
    }

    clearUploadProgressBinding(resetState: false)
    uploadProgressLocalId = localDocumentId
    let uploadId = "document_\(localDocumentId)"
    if uploadProgressSnapshot?.id != uploadId {
      uploadProgressSnapshot = .processing(id: uploadId)
    }

    let fallbackTotalBytes = Int64(document.size ?? 0)
    documentState = determineDocumentState(document)

    uploadProgressBindingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if let current = await FileUploader.shared.currentDocumentProgress(documentLocalId: localDocumentId) {
        guard !Task.isCancelled, self.uploadProgressLocalId == localDocumentId else { return }
        self.applyUploadProgress(current, localDocumentId: localDocumentId, fallbackTotalBytes: fallbackTotalBytes)
      }

      let publisher = await FileUploader.shared.documentProgressPublisher(documentLocalId: localDocumentId)
      guard !Task.isCancelled, self.uploadProgressLocalId == localDocumentId else { return }

      self.uploadProgressBindingTask = nil
      self.uploadProgressSubscription = publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] snapshot in
          guard let self else { return }
          self.applyUploadProgress(snapshot, localDocumentId: localDocumentId, fallbackTotalBytes: fallbackTotalBytes)
        }
    }
  }

  private func applyUploadProgress(
    _ snapshot: UploadProgressSnapshot,
    localDocumentId: Int64,
    fallbackTotalBytes: Int64
  ) {
    guard document?.id == localDocumentId else { return }
    uploadProgressSnapshot = snapshot

    switch snapshot.stage {
      case .processing:
        isUploadProcessing = true
        let totalBytes = max(snapshot.totalBytes, fallbackTotalBytes)
        updateUploadProgress(bytesSent: 0, totalBytes: totalBytes)
      case .uploading:
        isUploadProcessing = false
        let totalBytes = snapshot.totalBytes > 0 ? snapshot.totalBytes : fallbackTotalBytes
        updateUploadProgress(bytesSent: snapshot.bytesSent, totalBytes: totalBytes)
      case .completed:
        isUploadProcessing = false
        completeUpload()
      case .failed:
        isUploadProcessing = false
        failUpload()
    }
  }

  private func clearUploadProgressBinding(resetState: Bool) {
    isUploadProcessing = false
    uploadProgressBindingTask?.cancel()
    uploadProgressBindingTask = nil
    uploadProgressSubscription?.cancel()
    uploadProgressSubscription = nil
    uploadProgressLocalId = nil
    if resetState {
      uploadProgressSnapshot = nil
    }
  }

  // MARK: - Document State Management

  private func determineDocumentState(_ document: Document) -> DocumentState {
    switch pendingUploadDisplayState(document) {
      case .failed:
        return .uploadFailed
      case .inactive:
        break
      case .processing:
        return .uploading(bytesSent: 0, totalBytes: Int64(document.size ?? 0))
      case let .uploading(bytesSent, totalBytes):
        return .uploading(bytesSent: bytesSent, totalBytes: totalBytes)
    }

    if let localPath = document.localPath {
      let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
      let fileURL = cacheDirectory.appendingPathComponent(localPath)

      if FileManager.default.fileExists(atPath: fileURL.path) {
        documentURL = fileURL
        return .locallyAvailable
      }
    }

    // Use DocumentInfo.id consistently so forwarded copies follow the same progress stream.
    guard let documentInfo else { return .needsDownload }
    let documentId = documentInfo.id
    let progress = FileDownloader.shared.currentDocumentProgress(documentId: documentId)
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) || progress?.isLiveOrCompleting == true {
      let bytesReceived = progress?.bytesReceived ?? 0
      let totalBytes = progress?.displayTotalBytes(fallback: Int64(document.size ?? 0)) ?? Int64(document.size ?? 0)
      return .downloading(bytesReceived: bytesReceived, totalBytes: totalBytes)
    }

    return .needsDownload
  }

  private func pendingUploadDisplayState(_ document: Document) -> DocumentPendingUploadDisplayState {
    let progress: UploadProgressSnapshot?
    if let id = document.id, uploadProgressSnapshot?.id == "document_\(id)" {
      progress = uploadProgressSnapshot
    } else {
      progress = nil
    }

    return DocumentPendingUploadDisplayState.resolve(
      isPendingMessage: isPendingOutgoingUploadMessage(),
      isFailedMessage: fullMessage?.message.status == .failed,
      localDocumentId: document.id,
      progress: progress
    )
  }

  private func isPendingOutgoingUploadMessage() -> Bool {
    fullMessage?.message.status == .sending && document?.cdnUrl == nil
  }

  // MARK: - Progress Monitoring

  private func startMonitoringProgress() {
    guard let documentInfo else { return }

    progressSubscription?.cancel()

    let documentId = documentInfo.id
    if let progress = FileDownloader.shared.currentDocumentProgress(documentId: documentId) {
      applyDownloadProgress(progress, documentId: documentId)
    }

    progressSubscription = FileDownloader.shared.documentProgressPublisher(documentId: documentId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self else { return }

        Self.log.trace("📄 Document \(documentId) progress: \(progress)")
        self.applyDownloadProgress(progress, documentId: documentId)
      }
  }

  private func applyDownloadProgress(_ progress: DownloadProgress, documentId: Int64) {
    guard documentInfo?.id == documentId else { return }

    if let error = progress.error {
      Self.log.error("Document download failed:", error: error)
      documentState = .needsDownload
      return
    }

    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) || progress.isLiveOrCompleting {
      documentState = .downloading(
        bytesReceived: progress.bytesReceived,
        totalBytes: progress.displayTotalBytes(fallback: Int64(document?.size ?? 0))
      )
    }
  }

  @objc func handleDocumentUploadStarted(_ notification: Notification) {
    let notificationDocumentId = notification.userInfo?["documentId"] as? Int64
    let currentDocumentId = document?.id

    Self.log.trace(
        "📤 Upload notification received - notification ID: \(notificationDocumentId ?? -1), current ID: \(currentDocumentId ?? -1)"
      )

    guard let documentId = notificationDocumentId,
          let document,
          document.id == documentId
    else {
      Self.log.trace("📤 Upload notification ignored - IDs don't match")
      return
    }

    Self.log.trace("📤 Document upload started for document ID: \(documentId)")
    DispatchQueue.main.async { [weak self] in
      self?.setUploadingState()
    }
  }

  @objc func handleDocumentUploadCompleted(_ notification: Notification) {
    guard let documentId = notification.userInfo?["documentId"] as? Int64,
          let document,
          document.id == documentId
    else { return }

    Self.log.trace("Document upload completed for document ID: \(documentId)")
    DispatchQueue.main.async { [weak self] in
      self?.completeUpload()
    }
  }

  @objc func handleDocumentUploadFailed(_ notification: Notification) {
    guard let documentId = notification.userInfo?["documentId"] as? Int64,
          let document,
          document.id == documentId
    else { return }

    let error = notification.userInfo?["error"] as? Error
    Self.log.error("Document upload failed for document ID: \(documentId)", error: error)
    DispatchQueue.main.async { [weak self] in
      self?.failUpload()
    }
  }

  @objc func handleMessageStatusChanged(_ notification: Notification) {
    guard let messageId = notification.userInfo?["messageId"] as? Int64,
          let fullMessage,
          fullMessage.message.messageId == messageId
    else { return }

    let newStatus = notification.userInfo?["status"] as? MessageSendingStatus
    Self.log.trace("📤 Message status changed for message \(messageId): \(String(describing: newStatus))")

    // If message is no longer sending and has document, complete upload
    if newStatus != .sending,
       case .uploading = documentState
    {
      Self.log.trace("📤 Message no longer sending - completing upload")
      DispatchQueue.main.async { [weak self] in
        self?.completeUpload()
      }
    }
  }

  deinit {
    progressSubscription?.cancel()
    clearUploadProgressBinding(resetState: true)
    NotificationCenter.default.removeObserver(self)
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview == nil {
      progressSubscription?.cancel()
      progressSubscription = nil
      clearUploadProgressBinding(resetState: false)
    } else {
      syncUploadProgressBinding()
      if let document, case .downloading = determineDocumentState(document) {
        startMonitoringProgress()
      }
      requestAutoDownloadIfNeeded()
    }
  }

  private func requestAutoDownloadIfNeeded() {
    guard case .needsDownload = documentState else { return }
    guard let documentInfo, let document else { return }
    guard document.cdnUrl?.isEmpty == false else { return }
    guard !FileDownloader.shared.isDocumentDownloadActive(documentId: documentInfo.id) else { return }

    let sizeBytes = document.size.map(Int64.init)
    guard AutoDownloadPolicy.shouldDownload(kind: .file, sizeBytes: sizeBytes) else { return }

    downloadFile()
  }
}

private extension DownloadProgress {
  var isLiveOrCompleting: Bool {
    error == nil && bytesReceived > 0 && !isComplete
  }

  func displayTotalBytes(fallback: Int64) -> Int64 {
    let safeFallback = max(0, fallback)
    return totalBytes > 0 ? totalBytes : max(bytesReceived, safeFallback)
  }
}

// MARK: - UI Element Creation

extension DocumentView {
  static func createHorizantalStackView() -> UIStackView {
    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.spacing = 8
    stackView.alignment = .center
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }

  static func createTextsStackView() -> UIStackView {
    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.spacing = 0
    stackView.distribution = .fill
    stackView.alignment = .center
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }

  static func createVerticalStackView() -> UIStackView {
    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.spacing = 2
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }

  static func createFileIconButton() -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    UIView.performWithoutAnimation {
      button.layer.cornerRadius = 19
    }
    button.clipsToBounds = true
    button.clipsToBounds = true
    return button
  }

  static func createThumbnailView() -> PlatformPhotoView {
    let view = PlatformPhotoView()
    view.photoContentMode = .aspectFit
    view.showsTinyThumbnailBackground = true
    view.showsLoadingPlaceholder = true
    view.isUserInteractionEnabled = false
    view.isHidden = true
    return view
  }

  static func createThumbnailTransferOverlay() -> UIView {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    view.backgroundColor = .black.withAlphaComponent(0.38)
    view.layer.cornerRadius = 19
    view.isHidden = true
    return view
  }

  static func createFileIcon() -> UIImageView {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    return imageView
  }

  static func createFileNameLabel() -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15)
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingMiddle
    return label
  }

  static func createFileSizeLabel() -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13)
    return label
  }
}

// MARK: - QuickLook Integration

extension DocumentView: QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    Self.log.trace("📄 numberOfPreviewItems called - returning: \(documentURL != nil ? 1 : 0)")
    return documentURL != nil ? 1 : 0
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    Self.log.trace("📄 previewItemAt index: \(index) - URL: \(documentURL?.path ?? "nil")")
    guard let documentURL else {
      Self.log.error("📄 No documentURL available for preview item")
      fatalError("No document URL available")
    }
    return documentURL as QLPreviewItem
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    Self.log.trace("📄 previewControllerDidDismiss called")
    previewController = nil
  }
}

// MARK: - UIDocumentInteractionController Integration

extension DocumentView: UIDocumentInteractionControllerDelegate {
  func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController)
    -> UIViewController
  {
    findViewController() ?? UIViewController()
  }

  func documentInteractionControllerDidDismissOptionsMenu(_ controller: UIDocumentInteractionController) {
    documentInteractionController = nil
  }

  func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
    documentInteractionController = nil
  }
}

import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import QuickLook
import UIKit

class DocumentView: UIView {
  // MARK: - Properties

  private var fullMessage: FullMessage?
  private var outgoing: Bool
  private var isBeingRemoved = false


  enum DocumentState: Equatable {
    case locallyAvailable
    case needsDownload
    case downloading(bytesReceived: Int64, totalBytes: Int64)
    case uploading(bytesSent: Int64, totalBytes: Int64)
  }

  private var progressSubscription: AnyCancellable?
  private var uploadProgressSubscription: AnyCancellable?
  private var uploadProgressBindingTask: Task<Void, Never>?
  private var isUploadProcessing = false
  private var documentState: DocumentState = .needsDownload {
    didSet {
      updateUIForDocumentState()
    }
  }

  private var previewController: QLPreviewController?
  private var documentInteractionController: UIDocumentInteractionController?
  private var documentURL: URL?

  // Progress border
  private let progressLayer = CAShapeLayer()
  private var rotationAnimation: CABasicAnimation?

  var documentInfo: DocumentInfo? {
    fullMessage?.documentInfo
  }

  var document: Document? {
    documentInfo?.document
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

    // Determine initial state
    if let document {
      documentState = determineDocumentState(document)
    }

    // Check if this is a sending message with document - show uploading state
    if let message = fullMessage?.message,
       message.status == .sending,
       message.documentId != nil
    {
      Log.shared.debug("📤 Message is sending with document - setting uploading state")
      documentState = .uploading(bytesSent: 0, totalBytes: Int64(document?.size ?? 0))
      startMonitoringUploadProgress()
    }

    updateUIForDocumentState()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDocumentTappedNotification(_:)),
      name: Notification.Name("DocumentTapped"),
      object: nil
    )

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
    addGestureRecognizer(tapGesture)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Views

  let horizantalStackView = createHorizantalStackView()
  let textsStackView = createTextsStackView()
  let fileIconButton = createFileIconButton()
  let iconView = createFileIcon()
  let verticalStackView = createVerticalStackView()
  let fileNameLabel = createFileNameLabel()
  let fileSizeLabel = createFileSizeLabel()

  // MARK: - Setup & helpers

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
    fileIconButton.addSubview(iconView)
    horizantalStackView.addArrangedSubview(verticalStackView)
    verticalStackView.addArrangedSubview(fileNameLabel)
    verticalStackView.addArrangedSubview(fileSizeLabel)

    NSLayoutConstraint.activate([
      horizantalStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      horizantalStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      horizantalStackView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      horizantalStackView.bottomAnchor.constraint(equalTo: bottomAnchor),

      fileIconButton.widthAnchor.constraint(equalToConstant: 38),
      fileIconButton.heightAnchor.constraint(equalToConstant: 38),

      iconView.centerXAnchor.constraint(equalTo: fileIconButton.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: fileIconButton.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 22),
      iconView.heightAnchor.constraint(equalToConstant: 22),
    ])

    fileIconButton.addTarget(self, action: #selector(fileIconButtonTapped), for: .touchUpInside)
  }

  private func setupProgressLayer() {
    let circleRadius = 19
    let center = CGPoint(x: circleRadius, y: circleRadius)

    // Create a circular border progress layer
    progressLayer.frame = CGRect(x: 0, y: 0, width: circleRadius * 2, height: circleRadius * 2)
    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.strokeColor = progressBarColor.cgColor
    progressLayer.lineWidth = 2
    progressLayer.lineCap = .round

    // Start with no progress (empty path)
    updateProgressPath(progress: 0.0)

    fileIconButton.layer.addSublayer(progressLayer)
  }

  private func updateProgressPath(progress: CGFloat) {
    let circleRadius: CGFloat = 19
    let center = CGPoint(x: circleRadius, y: circleRadius)
    let radius = circleRadius - 1

    if progress <= 0 {
      // No progress - empty path
      progressLayer.path = UIBezierPath().cgPath
      return
    }

    // Create a circular border progress indicator
    let startAngle: CGFloat = -CGFloat.pi / 2 // Start at top
    let endAngle: CGFloat = startAngle + (2 * CGFloat.pi * progress)

    let path = UIBezierPath()
    path.addArc(
      withCenter: center,
      radius: radius,
      startAngle: startAngle,
      endAngle: endAngle,
      clockwise: true
    )

    progressLayer.path = path.cgPath
  }

  private func showUploadingSpinner() {
    let circleRadius: CGFloat = 19
    let center = CGPoint(x: circleRadius, y: circleRadius)
    let radius = circleRadius - 2 // Account for stroke width

    // Create a 1/9 arc (40 degrees) as border
    let segmentAngle: CGFloat = (2 * CGFloat.pi) / 9 // 40 degrees (1/9 of circle)
    let startAngle: CGFloat = -CGFloat.pi / 2 // Start at top
    let endAngle: CGFloat = startAngle + segmentAngle

    let path = UIBezierPath()
    path.addArc(
      withCenter: center,
      radius: radius,
      startAngle: startAngle,
      endAngle: endAngle,
      clockwise: true
    )

    progressLayer.path = path.cgPath

    // Create rotation animation - slower speed
    let rotation = CABasicAnimation(keyPath: "transform.rotation")
    rotation.fromValue = 0
    rotation.toValue = 2 * CGFloat.pi
    rotation.duration = 1.5 // Slower: 1.5 seconds per rotation
    rotation.repeatCount = .infinity
    rotation.isRemovedOnCompletion = false

    progressLayer.add(rotation, forKey: "rotation")
    rotationAnimation = rotation
  }

  private func hideUploadingSpinner() {
    progressLayer.removeAnimation(forKey: "rotation")
    rotationAnimation = nil
    progressLayer.path = UIBezierPath().cgPath
  }

  private var fileSizeMinWidthConstraint: NSLayoutConstraint?

  func setupContent() {
    // Colors
    fileNameLabel.textColor = textColor
    fileSizeLabel.textColor = labelColor
    fileIconButton.backgroundColor = fileIconWrapperColor

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

  func update(with fullMessage: FullMessage, outgoing: Bool) {
    self.fullMessage = fullMessage
    self.outgoing = outgoing
    isBeingRemoved = false
    progressSubscription?.cancel()
    progressSubscription = nil
    clearUploadProgressBinding()

    setupContent()

    if let document {
      documentState = determineDocumentState(document)
    } else {
      documentState = .needsDownload
    }

    if fullMessage.message.status == .sending,
       fullMessage.message.documentId != nil,
       let document
    {
      documentState = .uploading(bytesSent: 0, totalBytes: Int64(document.size ?? 0))
      startMonitoringUploadProgress()
    }

    updateUIForDocumentState()
    invalidateIntrinsicContentSize()
  }

  @objc func fileIconButtonTapped() {
    switch documentState {
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

  private func updateFileIcon() {
    switch documentState {
      case .needsDownload:
        iconView.image = UIImage(systemName: "arrow.down")
        iconView.tintColor = outgoing ? .white : ThemeManager.shared.selected.accent

      case .downloading:
        iconView.image = UIImage(systemName: "xmark")
        iconView.tintColor = outgoing ? .white : ThemeManager.shared.selected.accent

      case .uploading:
        iconView.image = UIImage(systemName: "xmark")
        iconView.tintColor = outgoing ? .white : ThemeManager.shared.selected.accent

      case .locallyAvailable:
        let iconName = DocumentIconResolver.symbolName(
          mimeType: document?.mimeType,
          fileName: document?.fileName,
          style: .filled
        )
        iconView.image = UIImage(systemName: iconName)
        iconView.tintColor = outgoing ? .white : .systemGray
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
        case .locallyAvailable:
          hideUploadingSpinner()
          updateProgressPath(progress: 0.0)
          fileSizeLabel.text = FileHelpers.formatFileSize(UInt64(document?.size ?? 0))

        case .needsDownload:
          hideUploadingSpinner()
          updateProgressPath(progress: 0.0)
          fileSizeLabel.text = FileHelpers.formatFileSize(UInt64(document?.size ?? 0))

        case let .downloading(bytesReceived, totalBytes):
          hideUploadingSpinner()
          let progress = Double(bytesReceived) / Double(totalBytes)
          updateProgressPath(progress: CGFloat(progress))

          let downloadedStr = FileHelpers.formatFileSize(UInt64(bytesReceived))
          let totalStr = FileHelpers.formatFileSize(UInt64(totalBytes))
          fileSizeLabel.text = "\(downloadedStr) / \(totalStr)"

        case let .uploading(bytesSent, totalBytes):
          showUploadingSpinner()
          if isUploadProcessing {
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

    FileDownloader.shared.downloadDocument(document: documentInfo, for: fullMessage.message) { [weak self] result in
      guard let self else { return }

      DispatchQueue.main.async {
        switch result {
          case .success:
            self.documentState = .locallyAvailable

          case let .failure(error):
            Log.shared.error("Document download failed:", error: error)
            self.documentState = .needsDownload
        }
      }
    }
  }

  func cancelDownload() {
    if case .downloading = documentState {
      if let documentInfo {
        FileDownloader.shared.cancelDocumentDownload(documentId: documentInfo.id)
      }

      documentState = .needsDownload

      progressSubscription?.cancel()
      progressSubscription = nil
    }
  }

  func cancelUpload() {
    if case .uploading = documentState {
      Log.shared.debug("Upload cancellation requested - cancelling message transaction")

      // Mark as being removed to prevent further interactions
      isBeingRemoved = true

      // Cancel the message transaction if it exists
      if let message = fullMessage?.message,
         let transactionId = message.transactionId,
         !transactionId.isEmpty
      {
        Log.shared.debug("Canceling message with transaction ID: \(transactionId)")
        Transactions.shared.cancel(transactionId: transactionId)

        // Delete the message from the database
        let chatId = message.chatId
        let messageId = message.messageId
        let peerId = message.peerId

        Task(priority: .userInitiated) {
          let _ = try? await AppDatabase.shared.dbWriter.write { db in
            try Message
              .filter(Column("chatId") == chatId)
              .filter(Column("messageId") == messageId)
              .deleteAll(db)
          }

          MessagesPublisher.shared
            .messagesDeleted(messageIds: [messageId], peer: peerId)
        }

        // Don't immediately remove the view - let MessagesPublisher handle the UI updates
        // The message collection view will properly remove the entire message cell
      } else {
        Log.shared.warning("No transaction ID found for message - cannot cancel upload")
      }

      hideUploadingSpinner()
      progressSubscription?.cancel()
      progressSubscription = nil
      clearUploadProgressBinding()
    }
  }

  func openFile() {
    Log.shared.debug("📄 openFile() called")

    guard
      let document,
      let localPath = document.localPath
    else {
      Log.shared
        .error(
          "📄 Cannot open document: No local path available - document: \(document?.fileName ?? "nil"), localPath: \(document?.localPath ?? "nil")"
        )
      return
    }

    Log.shared
      .debug(
        "📄 Document details - fileName: \(document.fileName ?? "unknown"), localPath: \(localPath), size: \(document.size ?? 0)"
      )

    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    let fileURL = cacheDirectory.appendingPathComponent(localPath)

    Log.shared.debug("📄 Full file path: \(fileURL.path)")
    Log.shared.debug("📄 Cache directory: \(cacheDirectory.path)")

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      Log.shared.error("📄 File does not exist at path: \(fileURL.path)")
      Log.shared
        .debug("📄 Directory contents: \(try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path))")
      documentState = .needsDownload
      return
    }

    // Get file attributes for debugging
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      Log.shared.debug("📄 File attributes: \(attributes)")
    } catch {
      Log.shared.error("📄 Failed to get file attributes: \(error)")
    }

    documentURL = fileURL

    // Check file extension to avoid QuickLook for problematic file types
    let fileExtension = fileURL.pathExtension.lowercased()
    let problematicExtensions = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx"]

    if problematicExtensions.contains(fileExtension) {
      Log.shared
        .debug("📄 File type .\(fileExtension) may cause QuickLook crashes - using UIDocumentInteractionController")
      openWithDocumentInteraction(fileURL: fileURL)
      return
    }

    Log.shared.debug("📄 About to check QLPreviewController.canPreview for: \(fileURL)")

    // Check if QuickLook can preview this file
    let canPreview = QLPreviewController.canPreview(fileURL as QLPreviewItem)
    Log.shared.debug("📄 QLPreviewController.canPreview result: \(canPreview)")

    if canPreview {
      Log.shared.debug("📄 Using QuickLook for preview")
      openWithQuickLook(fileURL: fileURL)
    } else {
      Log.shared.debug("📄 QuickLook can't preview, using UIDocumentInteractionController")
      openWithDocumentInteraction(fileURL: fileURL)
    }
  }

  private func openWithQuickLook(fileURL: URL) {
    Log.shared.debug("📄 openWithQuickLook() called for: \(fileURL)")

    let previewController = QLPreviewController()
    previewController.dataSource = self
    previewController.delegate = self
    self.previewController = previewController

    guard let viewController = findViewController() else {
      Log.shared.error("📄 Cannot find view controller to present QuickLook preview")
      Log.shared.debug("📄 Falling back to document interaction")
      openWithDocumentInteraction(fileURL: fileURL)
      return
    }

    Log.shared.debug("📄 Found view controller: \(type(of: viewController))")
    Log.shared.debug("📄 About to present QLPreviewController")

    DispatchQueue.main.async {
      Log.shared.debug("📄 Presenting QLPreviewController on main thread")
      viewController.present(previewController, animated: true) {
        Log.shared.debug("📄 QLPreviewController presentation completed")
      }
    }
  }

  private func openWithDocumentInteraction(fileURL: URL) {
    let documentInteractionController = UIDocumentInteractionController(url: fileURL)
    documentInteractionController.delegate = self
    self.documentInteractionController = documentInteractionController

    guard let viewController = findViewController() else {
      Log.shared.error("Cannot find view controller to present document interaction")
      return
    }

    // Try to present preview first
    if documentInteractionController.presentPreview(animated: true) {
      Log.shared.debug("Presented document preview using UIDocumentInteractionController")
    } else {
      // If preview fails, show options menu
      let rect = bounds
      if documentInteractionController.presentOptionsMenu(from: rect, in: self, animated: true) {
        Log.shared.debug("Presented document options menu using UIDocumentInteractionController")
      } else {
        Log.shared.error("Failed to present document using UIDocumentInteractionController")
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
    documentState = .uploading(bytesSent: 0, totalBytes: fileSize)

    startMonitoringUploadProgress()
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
    hideUploadingSpinner()
    documentState = .locallyAvailable
    clearUploadProgressBinding()
  }

  func failUpload() {
    isUploadProcessing = false
    hideUploadingSpinner()
    documentState = .locallyAvailable
    clearUploadProgressBinding()
  }

  private func startMonitoringUploadProgress() {
    clearUploadProgressBinding()

    guard let document else { return }
    let fallbackTotalBytes = Int64(document.size ?? 0)

    guard let localDocumentId = document.id else {
      Log.shared.warning("Document upload progress unavailable without local document ID")
      DispatchQueue.main.async { [weak self] in
        self?.updateUploadProgress(bytesSent: 0, totalBytes: fallbackTotalBytes)
      }
      return
    }

    uploadProgressBindingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let publisher = await FileUploader.shared.documentProgressPublisher(documentLocalId: localDocumentId)
      guard !Task.isCancelled else { return }

      self.uploadProgressBindingTask = nil
      self.uploadProgressSubscription = publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] snapshot in
          guard let self else { return }

          switch snapshot.stage {
            case .processing:
              self.isUploadProcessing = true
              let totalBytes = max(snapshot.totalBytes, fallbackTotalBytes)
              self.updateUploadProgress(bytesSent: 0, totalBytes: totalBytes)
            case .uploading:
              self.isUploadProcessing = false
              let totalBytes = snapshot.totalBytes > 0 ? snapshot.totalBytes : fallbackTotalBytes
              self.updateUploadProgress(bytesSent: snapshot.bytesSent, totalBytes: totalBytes)
            case .completed:
              self.isUploadProcessing = false
              self.completeUpload()
            case .failed:
              self.isUploadProcessing = false
              self.failUpload()
          }
        }
    }
  }

  private func clearUploadProgressBinding() {
    isUploadProcessing = false
    uploadProgressBindingTask?.cancel()
    uploadProgressBindingTask = nil
    uploadProgressSubscription?.cancel()
    uploadProgressSubscription = nil
  }

  // MARK: - Document State Management

  private func determineDocumentState(_ document: Document) -> DocumentState {
    if let localPath = document.localPath {
      let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
      let fileURL = cacheDirectory.appendingPathComponent(localPath)

      if FileManager.default.fileExists(atPath: fileURL.path) {
        documentURL = fileURL
        return .locallyAvailable
      }
    }

    // Use documentInfo.id to match what FileDownloader uses
    guard let documentInfo else { return .needsDownload }
    let documentId = documentInfo.id
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
      return .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))
    }

    return .needsDownload
  }

  // MARK: - Progress Monitoring

  private func startMonitoringProgress() {
    guard let documentInfo else { return }

    progressSubscription?.cancel()

    let documentId = documentInfo.id
    progressSubscription = FileDownloader.shared.documentProgressPublisher(documentId: documentId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self else { return }

        Log.shared.debug("📄 Document \(documentId) progress: \(progress)")

        if progress.isComplete {
          documentState = .locallyAvailable
        } else if let error = progress.error {
          Log.shared.error("Document download failed:", error: error)
          documentState = .needsDownload
        } else if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(document?.size ?? 0)
          )
        } else if progress.bytesReceived > 0 {
          // We have progress but no active task - might be completing
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(document?.size ?? 0)
          )
        }
      }
  }

  @objc func handleDocumentTappedNotification(_ notification: Notification) {
    if let tappedMessage = notification.userInfo?["fullMessage"] as? FullMessage,
       let selfMessage = fullMessage,
       tappedMessage.message.messageId == selfMessage.message.messageId
    {
      viewTapped()
    }
  }

  @objc func handleDocumentUploadStarted(_ notification: Notification) {
    let notificationDocumentId = notification.userInfo?["documentId"] as? Int64
    let currentDocumentId = document?.id

    Log.shared
      .debug(
        "📤 Upload notification received - notification ID: \(notificationDocumentId ?? -1), current ID: \(currentDocumentId ?? -1)"
      )

    guard let documentId = notificationDocumentId,
          let document,
          document.id == documentId
    else {
      Log.shared.debug("📤 Upload notification ignored - IDs don't match")
      return
    }

    Log.shared.debug("📤 Document upload started for document ID: \(documentId)")
    DispatchQueue.main.async { [weak self] in
      self?.setUploadingState()
    }
  }

  @objc func handleDocumentUploadCompleted(_ notification: Notification) {
    guard let documentId = notification.userInfo?["documentId"] as? Int64,
          let document,
          document.id == documentId
    else { return }

    Log.shared.debug("Document upload completed for document ID: \(documentId)")
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
    Log.shared.error("Document upload failed for document ID: \(documentId)", error: error)
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
    Log.shared.debug("📤 Message status changed for message \(messageId): \(String(describing: newStatus))")

    // If message is no longer sending and has document, complete upload
    if newStatus != .sending,
       fullMessage.message.documentId != nil,
       case .uploading = documentState
    {
      Log.shared.debug("📤 Message no longer sending - completing upload")
      DispatchQueue.main.async { [weak self] in
        self?.completeUpload()
      }
    }
  }

  deinit {
    clearUploadProgressBinding()
    NotificationCenter.default.removeObserver(self)
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
    Log.shared.debug("📄 numberOfPreviewItems called - returning: \(documentURL != nil ? 1 : 0)")
    return documentURL != nil ? 1 : 0
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    Log.shared.debug("📄 previewItemAt index: \(index) - URL: \(documentURL?.path ?? "nil")")
    guard let documentURL else {
      Log.shared.error("📄 No documentURL available for preview item")
      fatalError("No document URL available")
    }
    return documentURL as QLPreviewItem
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    Log.shared.debug("📄 previewControllerDidDismiss called")
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

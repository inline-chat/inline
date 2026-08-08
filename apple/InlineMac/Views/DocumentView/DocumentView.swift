import AppKit
import Cocoa
import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import QuickLookUI

struct DocumentPresentationPlan: Equatable {
  static let iconSize: CGFloat = 36
  static let thumbnailSize: CGFloat = 70
  static let thumbnailPreferredWidth: CGFloat = 300
  static let thumbnailCornerRadius: CGFloat = 8
  static let iconSpacing: CGFloat = 8
  static let metadataSpacing: CGFloat = 8
  static let closeButtonSize: CGFloat = 24

  let size: CGSize
  let mediaFrame: CGRect
  let iconFrame: CGRect
  let fileNameFrame: CGRect
  let fileSizeFrame: CGRect
  let actionFrame: CGRect
  let showsAction: Bool
  let closeFrame: CGRect?

  static func preferredHeight(for documentInfo: DocumentInfo) -> CGFloat {
    documentInfo.thumbnail?.bestPhotoSize() == nil ? Theme.documentViewHeight : thumbnailSize
  }

  static func preferredWidth(for documentInfo: DocumentInfo) -> CGFloat {
    documentInfo.thumbnail?.bestPhotoSize() == nil ? Theme.documentViewWidth : thumbnailPreferredWidth
  }

  static func make(
    documentInfo: DocumentInfo,
    width: CGFloat,
    fileSizeWidth: CGFloat,
    actionWidth: CGFloat,
    allowsAction: Bool,
    showsClose: Bool
  ) -> Self {
    let height = preferredHeight(for: documentInfo)
    let hasThumbnail = documentInfo.thumbnail?.bestPhotoSize() != nil
    let mediaSize = hasThumbnail ? thumbnailSize : iconSize
    let mediaFrame = CGRect(
      x: 0,
      y: floor((height - mediaSize) / 2),
      width: mediaSize,
      height: mediaSize
    )
    let iconFrame = CGRect(
      x: floor(mediaFrame.midX - iconSize / 2),
      y: floor(mediaFrame.midY - iconSize / 2),
      width: iconSize,
      height: iconSize
    )
    let closeReservation: CGFloat = showsClose ? 32 : 0
    let textX = mediaFrame.maxX + iconSpacing
    let availableTextWidth = max(0, width - textX - closeReservation)
    let labelHeight: CGFloat = 16
    let centerY = floor(height / 2)
    let resolvedActionWidth = min(actionWidth, 120)
    let showsAction = allowsAction &&
      fileSizeWidth + metadataSpacing + resolvedActionWidth <= availableTextWidth
    let actionX = max(textX, width - closeReservation - resolvedActionWidth)
    let resolvedFileSizeWidth = min(
      fileSizeWidth,
      showsAction ? max(0, actionX - textX - metadataSpacing) : availableTextWidth
    )

    return Self(
      size: CGSize(width: width, height: height),
      mediaFrame: mediaFrame,
      iconFrame: iconFrame,
      fileNameFrame: CGRect(x: textX, y: centerY + 1, width: availableTextWidth, height: labelHeight),
      fileSizeFrame: CGRect(
        x: textX,
        y: centerY - labelHeight - 1,
        width: resolvedFileSizeWidth,
        height: labelHeight
      ),
      actionFrame: CGRect(
        x: actionX,
        y: centerY - labelHeight - 2,
        width: showsAction ? resolvedActionWidth : 0,
        height: labelHeight + 4
      ),
      showsAction: showsAction,
      closeFrame: showsClose
        ? CGRect(x: max(0, width - closeButtonSize), y: floor(centerY - closeButtonSize / 2), width: closeButtonSize, height: closeButtonSize)
        : nil
    )
  }
}

class DocumentView: NSView {
  private static var uploadRingSize: CGFloat = 32
  private static var uploadCancelButtonSize: CGFloat = 18

  private enum Symbol {
    static let download = "arrow.down"
    static let cancel = "xmark"
  }

  enum DocumentState: Equatable {
    case locallyAvailable
    case needsDownload
    case downloading(bytesReceived: Int64, totalBytes: Int64)
    case uploadProcessing
    case uploading(bytesSent: Int64, totalBytes: Int64)
  }

  private var downloadProgressSubscription: AnyCancellable?
  private var uploadProgressSubscription: AnyCancellable?
  private var uploadProgressBindingTask: Task<Void, Never>?
  private var uploadProgressLocalId: Int64?
  private var uploadProgressSnapshot: UploadProgressSnapshot?
  private var white = false
  private var locallyAvailableFileURL: URL?
  private var thumbnailLoadGeneration = 0

  private var actionColor: NSColor {
    white ? .white : Theme.accentColor
  }

  private var hasLoadedThumbnail: Bool {
    !thumbnailImageView.isHidden && thumbnailImageView.image != nil
  }

  private var transferColor: NSColor {
    hasLoadedThumbnail ? .white : actionColor
  }

  private var isLocallyAvailable: Bool {
    if case .locallyAvailable = documentState { return true }
    return false
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshAppTheme()
  }

  // MARK: - UI Elements

  private lazy var thumbnailImageView: NSImageView = {
    let imageView = NSImageView()
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = DocumentPresentationPlan.thumbnailCornerRadius
    imageView.layer?.cornerCurve = .continuous
    imageView.layer?.masksToBounds = true
    imageView.isHidden = true
    return imageView
  }()

  private lazy var iconContainer: NSView = {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = white ?
      NSColor.white.withAlphaComponent(0.08).cgColor :
      NSColor.black.withAlphaComponent(0.05).cgColor
    container.layer?.cornerRadius = DocumentPresentationPlan.iconSize / 2
    return container
  }()

  private lazy var iconView: NSImageView = {
    let imageView = NSImageView()
    imageView.wantsLayer = true
    imageView.image = NSImage(systemSymbolName: Symbol.download, accessibilityDescription: nil)
    imageView.contentTintColor = white ? .white : .secondaryLabelColor

    let config = NSImage.SymbolConfiguration(pointSize: 21, weight: .regular)
    imageView.symbolConfiguration = config

    return imageView
  }()

  private lazy var uploadProgressRing: CircularTransferRingView = {
    let ring = CircularTransferRingView(
      configuration: .init(
        lineWidth: 1.5,
        minVisibleProgress: 0.06,
        rotationDuration: 1.5,
        ringInset: 1,
        strokeColor: actionColor
      )
    )
    ring.isHidden = true
    return ring
  }()

  private lazy var uploadCancelButton: NSButton = {
    let button = NSButton()
    button.bezelStyle = .shadowlessSquare
    button.isBordered = false
    button.imagePosition = .imageOnly
    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    button.image = NSImage(systemSymbolName: Symbol.cancel, accessibilityDescription: "Cancel Upload")?
      .withSymbolConfiguration(config)
    button.contentTintColor = actionColor
    button.setButtonType(.momentaryChange)
    button.focusRingType = .none
    button.target = self
    button.action = #selector(cancelPendingUpload)
    button.isHidden = true
    return button
  }()

  private let cancelIcon: NSImageView = {
    let imageView = NSImageView()
    imageView.wantsLayer = true
    imageView.image = NSImage(systemSymbolName: Symbol.cancel, accessibilityDescription: "Cancel")
    imageView.contentTintColor = Theme.accentColor

    let config = NSImage.SymbolConfiguration(pointSize: 21, weight: .regular)
    imageView.symbolConfiguration = config

    imageView.isHidden = true
    return imageView
  }()

  private lazy var fileNameLabel: NSTextField = {
    let label = NSTextField(labelWithString: "File")
    label.font = .systemFont(ofSize: 12, weight: .regular)
    label.maximumNumberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.textColor = white ? .white : .labelColor
    // Configure truncation
    label.cell?.lineBreakMode = .byTruncatingMiddle // Truncate in the middle for filenames
    label.cell?.truncatesLastVisibleLine = true
    return label
  }()

  private lazy var fileSizeLabel: NSTextField = {
    let label = NSTextField(labelWithString: "2 MB")
    label.font = .systemFont(ofSize: 12)
    label.maximumNumberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.cell?.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    label.textColor = white ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
    return label
  }()

  private lazy var actionButton: NSButton = {
    let button = NSButton(title: "Download", target: nil, action: #selector(actionButtonTapped))
    button.isBordered = false
    button.font = .systemFont(ofSize: 12)
    button.contentTintColor = actionColor
    return button
  }()

  private lazy var closeButton: NSButton = {
    let button = NSButton(frame: .zero)
    button.bezelStyle = .circular
    button.isBordered = false
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(handleClose)
    return button
  }()

  // MARK: - Properties

  var documentInfo: DocumentInfo
  var fullMessage: FullMessage?
  var removeAction: (() -> Void)?

  var documentState: DocumentState = .needsDownload {
    didSet {
      updateButtonState()
      updateIconForCurrentState()
    }
  }

  private func stopMonitoringProgress() {
    downloadProgressSubscription?.cancel()
    downloadProgressSubscription = nil
  }

  private func cancelExistingDownloadIfAny() {
    let documentId = documentInfo.id
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
      FileDownloader.shared.cancelDocumentDownload(documentId: documentId)
    }
    stopMonitoringProgress()
  }

  // MARK: - Initialization

  init(
    documentInfo: DocumentInfo,
    fullMessage: FullMessage? = nil,
    /// Set when rendering in compose and it renders a close button
    removeAction: (() -> Void)? = nil,
    white: Bool? = nil
  ) {
    self.documentInfo = documentInfo
    self.removeAction = removeAction
    self.fullMessage = fullMessage
    self.white = white ?? false
    locallyAvailableFileURL = Self.localDocumentURL(for: documentInfo)
    let height = DocumentPresentationPlan.preferredHeight(for: documentInfo)

    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: height))

    // Determine initial state
    documentState = determineDocumentState(documentInfo)

    setupView()
    syncUploadProgressBinding()
    updateUI()

    // Start monitoring progress if download is active
    if case .downloading = documentState {
      startMonitoringProgress()
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = .clear
    layer?.cornerRadius = 8

    actionButton.target = self

    // Add icon to container first
    iconContainer.addSubview(iconView)
    iconContainer.addSubview(uploadProgressRing)
    iconContainer.addSubview(uploadCancelButton)
    iconContainer.addSubview(cancelIcon)
    addSubview(thumbnailImageView)
    addSubview(iconContainer)
    addSubview(fileNameLabel)
    addSubview(fileSizeLabel)
    addSubview(actionButton)
    if removeAction != nil { addSubview(closeButton) }

    // Add gesture recognizer to cancel icon
    let tapGesture = NSClickGestureRecognizer(target: self, action: #selector(cancelDownload))
    cancelIcon.addGestureRecognizer(tapGesture)
    cancelIcon.isEnabled = true

    // Add gesture recognizers to icon and filename so they behave like the primary action button
    let iconTapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleIconOrNameClick))
    iconContainer.addGestureRecognizer(iconTapGesture)

    let thumbnailTapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleIconOrNameClick))
    thumbnailImageView.addGestureRecognizer(thumbnailTapGesture)
    thumbnailImageView.isEnabled = true

    let nameTapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleIconOrNameClick))
    fileNameLabel.addGestureRecognizer(nameTapGesture)
    fileNameLabel.isEnabled = true
  }

  override func layout() {
    super.layout()
    fileSizeLabel.sizeToFit()
    actionButton.sizeToFit()
    let plan = DocumentPresentationPlan.make(
      documentInfo: documentInfo,
      width: bounds.width,
      fileSizeWidth: fileSizeLabel.frame.width,
      actionWidth: actionButton.frame.width,
      allowsAction: allowsActionForCurrentState,
      showsClose: removeAction != nil
    )

    thumbnailImageView.frame = plan.mediaFrame
    iconContainer.frame = plan.iconFrame
    iconView.frame = iconContainer.bounds
    cancelIcon.frame = iconContainer.bounds
    uploadProgressRing.frame = NSRect(
      x: floor((DocumentPresentationPlan.iconSize - Self.uploadRingSize) / 2),
      y: floor((DocumentPresentationPlan.iconSize - Self.uploadRingSize) / 2),
      width: Self.uploadRingSize,
      height: Self.uploadRingSize
    )
    uploadCancelButton.frame = NSRect(
      x: floor((DocumentPresentationPlan.iconSize - Self.uploadCancelButtonSize) / 2),
      y: floor((DocumentPresentationPlan.iconSize - Self.uploadCancelButtonSize) / 2),
      width: Self.uploadCancelButtonSize,
      height: Self.uploadCancelButtonSize
    )
    fileNameLabel.frame = plan.fileNameFrame
    fileSizeLabel.frame = plan.fileSizeFrame
    actionButton.frame = plan.actionFrame
    actionButton.isHidden = !plan.showsAction
    if let closeFrame = plan.closeFrame { closeButton.frame = closeFrame }
  }

  private var allowsActionForCurrentState: Bool {
    switch documentState {
    case .locallyAvailable, .needsDownload:
      true
    case .downloading, .uploadProcessing, .uploading:
      false
    }
  }

  private func updateUI() {
    fileNameLabel.stringValue = documentInfo.document.fileName ?? "Unknown File"
    updateThumbnail()
    updateButtonState()
    updateIconForCurrentState()
  }

  private func updateThumbnail() {
    thumbnailLoadGeneration += 1
    let generation = thumbnailLoadGeneration
    thumbnailImageView.image = nil
    thumbnailImageView.isHidden = true

    guard let thumbnail = documentInfo.thumbnail,
          let size = thumbnail.bestPhotoSize()
    else {
      needsLayout = true
      return
    }

    guard let localPath = size.localPath else {
      if size.cdnUrl != nil {
        Task.detached { [thumbnail, message = fullMessage?.message] in
          await FileCache.shared.download(photo: thumbnail, reloadMessageOnFinish: message)
        }
      }
      needsLayout = true
      return
    }

    let url = FileCache.getUrl(for: .photos, localPath: localPath)
    let cacheKey = "document-thumb-\(documentInfo.id)"
    ImageCacheManager.shared.image(
      for: url,
      loadSync: false,
      cacheKey: cacheKey,
      targetSize: NSSize(
        width: DocumentPresentationPlan.thumbnailSize,
        height: DocumentPresentationPlan.thumbnailSize
      ),
      scale: window?.backingScaleFactor ?? 2
    ) { [weak self] image in
      guard let self, self.thumbnailLoadGeneration == generation else { return }
      self.thumbnailImageView.image = image
      self.thumbnailImageView.isHidden = image == nil
      self.updateButtonState()
      self.needsLayout = true
    }
  }

  /// Update the icon to match the current document state and theme
  private func updateIconForCurrentState() {
    iconView.contentTintColor = hasLoadedThumbnail ? .white : (white ? .white : .secondaryLabelColor)

    switch documentState {
      case .needsDownload:
        iconView.image = NSImage(systemSymbolName: Symbol.download, accessibilityDescription: "Download")
      case .locallyAvailable:
        iconView.image = NSImage(systemSymbolName: fileTypeSymbolName(), accessibilityDescription: nil)
      case .downloading:
        // Icon hidden while cancel is visible; keep the last file icon ready for completion
        iconView.image = NSImage(systemSymbolName: fileTypeSymbolName(), accessibilityDescription: nil)
      case .uploadProcessing, .uploading:
        iconView.image = NSImage(systemSymbolName: fileTypeSymbolName(), accessibilityDescription: nil)
    }

    // Keep the cancel icon color aligned with bubble style
    cancelIcon.contentTintColor = transferColor
    uploadCancelButton.contentTintColor = transferColor
    uploadProgressRing.setStrokeColor(transferColor)
  }

  private func fileTypeSymbolName() -> String {
    DocumentIconResolver.symbolName(
      mimeType: documentInfo.document.mimeType,
      fileName: documentInfo.document.fileName,
      style: .regular
    )
  }

  private func updateButtonState() {
    switch documentState {
      case .locallyAvailable:
        // Show normal document view
        iconView.isHidden = false
        uploadProgressRing.isHidden = true
        uploadCancelButton.isHidden = true
        cancelIcon.isHidden = true
        fileSizeLabel.stringValue = FileHelpers.formatFileSize(UInt64(documentInfo.document.size ?? 0))
        actionButton.title = "Show in Finder"
        actionButton.contentTintColor = actionColor
        updateIconForCurrentState()

      case .needsDownload:
        // Show download button
        iconView.isHidden = false
        uploadProgressRing.isHidden = true
        uploadCancelButton.isHidden = true
        cancelIcon.isHidden = true
        fileSizeLabel.stringValue = FileHelpers.formatFileSize(UInt64(documentInfo.document.size ?? 0))
        actionButton.title = "Download"
        actionButton.contentTintColor = actionColor
        updateIconForCurrentState()

      case let .downloading(bytesReceived, totalBytes):
        // Show download progress
        iconView.isHidden = true
        uploadProgressRing.isHidden = true
        uploadCancelButton.isHidden = true
        cancelIcon.isHidden = false

        // Ensure cancel icon matches the current bubble color scheme
        cancelIcon.contentTintColor = transferColor
        cancelIcon.image = NSImage(systemSymbolName: Symbol.cancel, accessibilityDescription: "Cancel")

        // Format the progress text
        let downloadedStr = FileHelpers.formatFileSize(UInt64(bytesReceived))
        let totalStr = FileHelpers.formatFileSize(UInt64(totalBytes))
        fileSizeLabel.stringValue = "\(downloadedStr) / \(totalStr)"

      case .uploadProcessing:
        iconView.isHidden = true
        cancelIcon.isHidden = true
        uploadProgressRing.isHidden = false
        uploadCancelButton.isHidden = false
        uploadProgressRing.setProgress(0)
        fileSizeLabel.stringValue = "Processing"

      case let .uploading(bytesSent, totalBytes):
        iconView.isHidden = true
        cancelIcon.isHidden = true
        uploadProgressRing.isHidden = false
        uploadCancelButton.isHidden = false
        let fractionCompleted = totalBytes > 0 ? CGFloat(Double(bytesSent) / Double(totalBytes)) : 0
        uploadProgressRing.setProgress(fractionCompleted)
        fileSizeLabel.stringValue = uploadProgressLabel(bytesSent: bytesSent, totalBytes: totalBytes)
    }

    needsLayout = true
    updateMediaOverlayAppearance()
  }

  private func updateMediaOverlayAppearance() {
    iconContainer.isHidden = hasLoadedThumbnail && isLocallyAvailable
    iconContainer.layer?.backgroundColor = if hasLoadedThumbnail {
      NSColor.black.withAlphaComponent(0.38).cgColor
    } else if white {
      NSColor.white.withAlphaComponent(0.08).cgColor
    } else {
      NSColor.black.withAlphaComponent(0.05).cgColor
    }
    updateIconForCurrentState()
  }

  // MARK: - Actions

  @objc private func cancelDownload() {
    // Only cancel if we're in downloading state
    if case .downloading = documentState {
      // Cancel the download
      FileDownloader.shared.cancelDocumentDownload(documentId: documentInfo.id)

      // Reset state
      documentState = .needsDownload

      // Clean up subscription
      stopMonitoringProgress()
    }
  }

  @objc private func cancelPendingUpload() {
    switch documentState {
    case .uploadProcessing, .uploading:
      cancelPendingDocumentMessage()
    default:
      return
    }
  }

  private func downloadAction(saveToDownloadsWhenFinished: Bool) {
    guard let fullMessage else {
      Log.shared.warning("Cannot download document without a message")
      return
    }

    // Prevent overlapping downloads for the same document by cancelling any existing task
    cancelExistingDownloadIfAny()

    // If we're already downloading, don't start a new download
    if case .downloading = documentState {
      return
    }

    // Set initial downloading state
    documentState = .downloading(bytesReceived: 0, totalBytes: Int64(documentInfo.document.size ?? 0))

    // Start monitoring progress
    startMonitoringProgress()

    // Start the download
    FileDownloader.shared.downloadDocument(document: documentInfo, for: fullMessage.message) { [weak self] result in
      guard let self else { return }

      switch result {
      case let .success(fileURL):
        DispatchQueue.main.async {
          self.locallyAvailableFileURL = fileURL
          self.documentState = .locallyAvailable
          self.stopMonitoringProgress()
          if saveToDownloadsWhenFinished {
            self.saveDownloadedFileToDownloads(sourceURL: fileURL)
          }
        }
      // Success - refresh document info
      // refreshDocumentInfo()
      case let .failure(error):
        Log.shared.error("Document download failed: \(error)")
        documentState = .needsDownload
        stopMonitoringProgress()
      }
    }
  }

  @objc private func actionButtonTapped() {
    switch documentState {
    case .locallyAvailable:
      showInFinder()

    case .needsDownload:
      downloadAction(saveToDownloadsWhenFinished: true)

    default:
      break
    }
  }

  deinit {
    stopMonitoringProgress()
    clearUploadProgressBinding(resetState: true)
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()

    if superview == nil {
      stopMonitoringProgress()
      clearUploadProgressBinding(resetState: false)
    } else {
      syncUploadProgressBinding()
      documentState = determineDocumentState(documentInfo)
      if case .downloading = documentState {
        startMonitoringProgress()
      }
      requestAutoDownloadIfNeeded()
    }
  }

  private func requestAutoDownloadIfNeeded() {
    guard superview != nil else { return }
    guard case .needsDownload = documentState else { return }
    guard documentInfo.document.cdnUrl?.isEmpty == false else { return }
    guard !FileDownloader.shared.isDocumentDownloadActive(documentId: documentInfo.id) else { return }

    let sizeBytes = documentInfo.document.size.map(Int64.init)
    guard AutoDownloadPolicy.shouldDownload(kind: .file, sizeBytes: sizeBytes) else { return }

    downloadAction(saveToDownloadsWhenFinished: false)
  }

  @objc private func handleClose() {
    removeAction?()
  }

  @objc private func handleIconOrNameClick() {
    switch documentState {
    case .locallyAvailable:
      openQuickLook()
    case .needsDownload:
      downloadAction(saveToDownloadsWhenFinished: false)
    case .downloading, .uploadProcessing, .uploading:
      break
    }
  }

  func update(with documentInfo: DocumentInfo, fullMessage: FullMessage? = nil) {
    // Update document info
    self.documentInfo = documentInfo
    if let fullMessage {
      self.fullMessage = fullMessage
    }
    locallyAvailableFileURL = Self.localDocumentURL(for: documentInfo)
    syncUploadProgressBinding()

    // Set initial state
    documentState = determineDocumentState(documentInfo)
    updateUI()

    // Start monitoring if downloading
    if case .downloading = documentState {
      startMonitoringProgress()
    } else {
      stopMonitoringProgress()
    }
    requestAutoDownloadIfNeeded()
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      QLPreviewPanel.shared()?.updateController()
    }
    return became
  }

  // Method to manually set the state
  func setState(_ state: DocumentState) {
    documentState = state
  }

  // MARK: - Document State Management

  private func determineDocumentState(_ documentInfo: DocumentInfo) -> DocumentState {
    switch pendingUploadDisplayState() {
    case .inactive:
      break
    case .processing:
      return .uploadProcessing
    case let .uploading(bytesSent, totalBytes):
      return .uploading(bytesSent: bytesSent, totalBytes: totalBytes)
    }

    if isDocumentAvailableLocally(documentInfo) {
      return .locallyAvailable
    }

    let documentId = documentInfo.id
    let progress = FileDownloader.shared.currentDocumentProgress(documentId: documentId)
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) || progress?.isLiveOrCompleting == true {
      return .downloading(
        bytesReceived: progress?.bytesReceived ?? 0,
        totalBytes: progress?.displayTotalBytes(fallback: Int64(documentInfo.document.size ?? 0))
          ?? Int64(documentInfo.document.size ?? 0)
      )
    }

    return .needsDownload
  }

  private func pendingUploadDisplayState() -> DocumentPendingUploadDisplayState {
    let progress: UploadProgressSnapshot?
    if let id = documentInfo.document.id, uploadProgressSnapshot?.id == "document_\(id)" {
      progress = uploadProgressSnapshot
    } else {
      progress = nil
    }

    return DocumentPendingUploadDisplayState.resolve(
      isPendingMessage: isPendingOutgoingUploadMessage(),
      localDocumentId: documentInfo.document.id,
      progress: progress
    )
  }

  private func isPendingOutgoingUploadMessage() -> Bool {
    fullMessage?.message.status == .sending
  }

  private func isDocumentAvailableLocally(_ documentInfo: DocumentInfo) -> Bool {
    guard let localPath = documentInfo.document.localPath, !localPath.isEmpty else {
      return false
    }

    return true
  }

  // MARK: - Progress Monitoring

  private func startMonitoringProgress() {
    downloadProgressSubscription?.cancel()

    Log.shared.info("Starting progress subscription for document \(documentInfo.id)")

    let documentId = documentInfo.id
    if let progress = FileDownloader.shared.currentDocumentProgress(documentId: documentId) {
      applyDownloadProgress(progress, documentId: documentId)
    }

    downloadProgressSubscription = FileDownloader.shared.documentProgressPublisher(documentId: documentId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self else { return }

        Log.shared.info("Document \(documentId) progress: \(progress)")
        self.applyDownloadProgress(progress, documentId: documentId)
      }
  }

  private func applyDownloadProgress(_ progress: DownloadProgress, documentId: Int64) {
    guard documentInfo.id == documentId else { return }

    if let error = progress.error {
      Log.shared.error("Document download failed: \(error)")
      documentState = .needsDownload
      stopMonitoringProgress()
      return
    }

    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) || progress.isLiveOrCompleting {
      documentState = .downloading(
        bytesReceived: progress.bytesReceived,
        totalBytes: progress.displayTotalBytes(fallback: Int64(documentInfo.document.size ?? 0))
      )
    }
  }

  private func syncUploadProgressBinding() {
    guard isPendingOutgoingUploadMessage(), let documentLocalId = documentInfo.document.id else {
      clearUploadProgressBinding(resetState: true)
      return
    }

    if uploadProgressLocalId == documentLocalId,
       uploadProgressBindingTask != nil || uploadProgressSubscription != nil
    {
      return
    }

    clearUploadProgressBinding(resetState: false)
    uploadProgressLocalId = documentLocalId
    let uploadId = "document_\(documentLocalId)"
    if uploadProgressSnapshot?.id != uploadId {
      uploadProgressSnapshot = .processing(id: uploadId)
    }

    uploadProgressBindingTask = Task { @MainActor [weak self] in
      guard let self else { return }

      if let current = await FileUploader.shared.currentDocumentProgress(documentLocalId: documentLocalId) {
        guard !Task.isCancelled, self.uploadProgressLocalId == documentLocalId else { return }
        self.applyUploadProgress(current, documentLocalId: documentLocalId)
      }

      let publisher = await FileUploader.shared.documentProgressPublisher(documentLocalId: documentLocalId)
      guard !Task.isCancelled, self.uploadProgressLocalId == documentLocalId else { return }

      self.uploadProgressBindingTask = nil
      self.uploadProgressSubscription = publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] progress in
          guard let self else { return }
          self.applyUploadProgress(progress, documentLocalId: documentLocalId)
        }
    }
  }

  private func applyUploadProgress(_ progress: UploadProgressSnapshot, documentLocalId: Int64) {
    guard uploadProgressLocalId == documentLocalId else { return }

    uploadProgressSnapshot = progress
    documentState = determineDocumentState(documentInfo)

    switch progress.stage {
    case .failed, .completed:
      clearUploadProgressBinding(resetState: false)
    case .processing, .uploading:
      break
    }
  }

  private func clearUploadProgressBinding(resetState: Bool) {
    uploadProgressBindingTask?.cancel()
    uploadProgressBindingTask = nil
    uploadProgressSubscription?.cancel()
    uploadProgressSubscription = nil
    uploadProgressLocalId = nil
    if resetState {
      uploadProgressSnapshot = nil
    }
  }

  private func uploadProgressLabel(bytesSent: Int64, totalBytes: Int64) -> String {
    "\(formatTransferBytes(bytesSent)) / \(formatTransferBytes(totalBytes))"
  }

  private func formatTransferBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
  }

  private func cancelPendingDocumentMessage() {
    guard let fullMessage, let documentLocalId = documentInfo.document.id else { return }

    clearUploadProgressBinding(resetState: false)

    Task {
      await FileUploader.shared.cancelDocumentUpload(documentLocalId: documentLocalId)
    }

    if let transactionId = fullMessage.message.transactionId, !transactionId.isEmpty {
      Transactions.shared.cancel(transactionId: transactionId)
    } else if let randomId = fullMessage.message.randomId {
      Task {
        Api.realtime.cancelTransaction(where: {
          guard $0.transaction.method == .sendMessage else { return false }
          guard case let .sendMessage(input) = $0.transaction.input else { return false }
          return input.randomID == randomId
        })
      }
    }

    Task(priority: .userInitiated) { [message = fullMessage.message] in
      let chatId = message.chatId
      let messageId = message.messageId
      let peerId = message.peerId

      do {
        try await AppDatabase.shared.dbWriter.write { db in
          try Message
            .filter(Column("chatId") == chatId)
            .filter(Column("messageId") == messageId)
            .deleteAll(db)
        }

        MessagesPublisher.shared.messagesDeleted(messageIds: [messageId], peer: peerId)
      } catch {
        Log.shared.error("Failed to delete local message row for document cancel", error: error)
      }
    }
  }
}

extension DocumentView: AppThemeRefreshable {
  func refreshAppTheme() {
    uploadProgressRing.setStrokeColor(actionColor)
    updateIconForCurrentState()
    updateButtonState()
  }
}

//
extension DocumentView {
  private func openQuickLook() {
    guard let sourceURL = currentLocalDocumentURL(),
          FileManager.default.fileExists(atPath: sourceURL.path),
          let panel = QLPreviewPanel.shared()
    else {
      return
    }

    locallyAvailableFileURL = sourceURL
    if panel.isVisible {
      panel.orderOut(nil)
    } else {
      window?.makeFirstResponder(self)
      panel.updateController()
      panel.makeKeyAndOrderFront(nil)
    }
  }

  private func showInFinder() {
    guard let sourceURL = currentLocalDocumentURL() else { return }
    revealDocumentInFinder(sourceURL: sourceURL)
  }

  // Helper method to create a unique filename with sequential numbering
  private func createUniqueFileName(_ fileName: String, inDirectory directory: URL) -> String {
    let fileManager = FileManager.default
    let parsedFileURL = URL(fileURLWithPath: fileName)
    let fileExtension = parsedFileURL.pathExtension.isEmpty ? "" : ".\(parsedFileURL.pathExtension)"
    let baseName = parsedFileURL.deletingPathExtension().lastPathComponent

    let regex = try? NSRegularExpression(pattern: " \\((\\d+)\\)$", options: [])
    let range = NSRange(baseName.startIndex ..< baseName.endIndex, in: baseName)

    let baseNameWithoutNumber: String
    let initialCounter: Int

    if let regex,
       let match = regex.firstMatch(in: baseName, options: [], range: range),
       let numberRange = Range(match.range(at: 1), in: baseName),
       let existingNumber = Int(baseName[numberRange]),
       let baseRange = Range(NSRange(location: 0, length: match.range.location), in: baseName)
    {
      baseNameWithoutNumber = String(baseName[baseRange])
      initialCounter = existingNumber + 1
    } else {
      baseNameWithoutNumber = baseName
      initialCounter = 1
    }

    var counter = initialCounter
    while true {
      let newFileName = "\(baseNameWithoutNumber) (\(counter))\(fileExtension)"
      let newFilePath = directory.appendingPathComponent(newFileName).path

      if !fileManager.fileExists(atPath: newFilePath) {
        return newFileName
      }

      counter += 1
    }
  }

  private func saveDownloadedFileToDownloads(sourceURL: URL) {
    do {
      _ = try ensureDocumentExistsInDownloads(sourceURL: sourceURL)
    } catch {
      Log.shared.error("Failed to save downloaded file to Downloads", error: error)
    }
  }

  private func revealDocumentInFinder(sourceURL: URL) {
    do {
      let destinationURL = try ensureDocumentExistsInDownloads(sourceURL: sourceURL)
      NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    } catch {
      Log.shared.error("Failed to reveal downloaded file in Finder", error: error)
      NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
    }
  }

  private func ensureDocumentExistsInDownloads(sourceURL: URL) throws -> URL {
    let downloadsURL = try downloadsDirectoryURL()
    let fileManager = FileManager.default
    let fileName = documentInfo.document.fileName ?? "Unknown File"
    let exactDestinationURL = downloadsURL.appendingPathComponent(fileName)

    if let existingURL = try findExistingDownloadedFile(sourceURL: sourceURL, in: downloadsURL, fileName: fileName) {
      return existingURL
    }

    let destinationURL = if fileManager.fileExists(atPath: exactDestinationURL.path) {
      downloadsURL.appendingPathComponent(createUniqueFileName(fileName, inDirectory: downloadsURL))
    } else {
      exactDestinationURL
    }

    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private func downloadsDirectoryURL() throws -> URL {
    if let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
      return downloadsURL
    }

    throw NSError(
      domain: "DocumentView",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Downloads directory is unavailable"]
    )
  }

  private func findExistingDownloadedFile(sourceURL: URL, in directory: URL, fileName: String) throws -> URL? {
    let fileManager = FileManager.default
    let exactMatchURL = directory.appendingPathComponent(fileName)

    if fileManager.fileExists(atPath: exactMatchURL.path),
       hasSameContent(sourceURL: sourceURL, destinationURL: exactMatchURL)
    {
      return exactMatchURL
    }

    let directoryContents = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )

    for candidateURL in directoryContents where isGeneratedDownloadName(candidateURL.lastPathComponent, for: fileName) {
      if hasSameContent(sourceURL: sourceURL, destinationURL: candidateURL) {
        return candidateURL
      }
    }

    return nil
  }

  private func isGeneratedDownloadName(_ candidateName: String, for originalFileName: String) -> Bool {
    let originalURL = URL(fileURLWithPath: originalFileName)
    let candidateURL = URL(fileURLWithPath: candidateName)
    let originalBaseName = originalURL.deletingPathExtension().lastPathComponent
    let candidateBaseName = candidateURL.deletingPathExtension().lastPathComponent

    guard candidateURL.pathExtension == originalURL.pathExtension else {
      return false
    }

    let escapedBaseName = NSRegularExpression.escapedPattern(for: originalBaseName)
    let pattern = "^" + escapedBaseName + " \\([0-9]+\\)$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return false
    }

    let range = NSRange(candidateBaseName.startIndex ..< candidateBaseName.endIndex, in: candidateBaseName)
    return regex.firstMatch(in: candidateBaseName, options: [], range: range) != nil
  }

  private func currentLocalDocumentURL() -> URL? {
    Self.localDocumentURL(for: documentInfo) ?? locallyAvailableFileURL
  }

  private static func localDocumentURL(for documentInfo: DocumentInfo) -> URL? {
    guard let localPath = documentInfo.document.localPath else { return nil }
    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    return cacheDirectory.appendingPathComponent(localPath)
  }

  // Simplified file comparison
  private func hasSameContent(sourceURL: URL, destinationURL: URL) -> Bool {
    let fileManager = FileManager.default

    do {
      // First check file sizes
      let sourceAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
      let destAttributes = try fileManager.attributesOfItem(atPath: destinationURL.path)

      let sourceSize = sourceAttributes[.size] as? UInt64 ?? 0
      let destSize = destAttributes[.size] as? UInt64 ?? 0

      if sourceSize != destSize {
        return false
      }

      // For small files, compare directly
      if sourceSize < 10_000_000 { // 10MB
        let sourceData = try Data(contentsOf: sourceURL)
        let destData = try Data(contentsOf: destinationURL)
        return sourceData == destData
      }

      // For larger files, compare modification dates and sizes only
      let sourceModDate = sourceAttributes[.modificationDate] as? Date
      let destModDate = destAttributes[.modificationDate] as? Date

      // If sizes match and dates are close, assume same file
      if let sourceDate = sourceModDate, let destDate = destModDate {
        return abs(sourceDate.timeIntervalSince(destDate)) < 1.0
      }

      return false
    } catch {
      Log.shared.error("Error comparing files", error: error)
      return false
    }
  }
}

// MARK: - Quick Look

extension DocumentView {
  override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
    guard let url = currentLocalDocumentURL() else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
  }
}

extension DocumentView: QLPreviewPanelDataSource {
  func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
    guard let url = currentLocalDocumentURL() else { return 0 }
    return FileManager.default.fileExists(atPath: url.path) ? 1 : 0
  }

  func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> QLPreviewItem! {
    self
  }
}

extension DocumentView: QLPreviewPanelDelegate {
  func previewPanel(_: QLPreviewPanel!, sourceFrameOnScreenFor _: QLPreviewItem!) -> NSRect {
    let sourceView = hasLoadedThumbnail ? thumbnailImageView : iconContainer
    let frameInWindow = sourceView.convert(sourceView.bounds, to: nil)
    return window?.convertToScreen(frameInWindow) ?? .zero
  }

  func previewPanel(
    _: QLPreviewPanel!,
    transitionImageFor _: QLPreviewItem!,
    contentRect _: UnsafeMutablePointer<NSRect>!
  ) -> Any! {
    thumbnailImageView.image ?? iconView.image
  }
}

extension DocumentView: QLPreviewItem {
  var previewItemURL: URL! {
    guard let url = currentLocalDocumentURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  var previewItemTitle: String! {
    documentInfo.document.fileName ?? "Document"
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

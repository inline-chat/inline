import AppKit
import Cocoa
import Combine
import Foundation
import GRDB
import InlineKit
import Logger

class DocumentView: NSView {
  private var height = Theme.documentViewHeight
  private static var iconCircleSize: CGFloat = 36
  private static var uploadRingSize: CGFloat = 32
  private static var uploadCancelButtonSize: CGFloat = 18
  private static var iconSpacing: CGFloat = 8
  private static var textsSpacing: CGFloat = 2

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

  // MARK: - UI Elements

  private lazy var iconContainer: NSView = {
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.wantsLayer = true
    container.layer?.backgroundColor = white ?
      NSColor.white.withAlphaComponent(0.08).cgColor :
      NSColor.black.withAlphaComponent(0.05).cgColor
    container.layer?.cornerRadius = DocumentView.iconCircleSize / 2
    return container
  }()

  private lazy var iconView: NSImageView = {
    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
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
        strokeColor: white ? .white : .systemBlue
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
    button.translatesAutoresizingMaskIntoConstraints = false
    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    button.image = NSImage(systemSymbolName: Symbol.cancel, accessibilityDescription: "Cancel Upload")?
      .withSymbolConfiguration(config)
    button.contentTintColor = white ? .white : .systemBlue
    button.setButtonType(.momentaryChange)
    button.focusRingType = .none
    button.target = self
    button.action = #selector(cancelPendingUpload)
    button.isHidden = true
    return button
  }()

  private let cancelIcon: NSImageView = {
    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.wantsLayer = true
    imageView.image = NSImage(systemSymbolName: Symbol.cancel, accessibilityDescription: "Cancel")
    imageView.contentTintColor = NSColor.systemBlue

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
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private lazy var fileSizeLabel: NSTextField = {
    let label = NSTextField(labelWithString: "2 MB")
    label.font = .systemFont(ofSize: 12)
    label.textColor = white ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private lazy var actionButton: NSButton = {
    let button = NSButton(title: "Download", target: nil, action: #selector(actionButtonTapped))
    button.isBordered = false
    button.font = .systemFont(ofSize: 12)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.contentTintColor = white ? .white : NSColor.controlAccentColor
    return button
  }()

  private let containerStackView: NSStackView = {
    let stackView = NSStackView()
    stackView.orientation = .horizontal
    stackView.spacing = DocumentView.iconSpacing
    stackView.alignment = .centerY // Vertical alignment
    stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }()

  private let textStackView: NSStackView = {
    let stackView = NSStackView()
    stackView.orientation = .vertical
    stackView.spacing = DocumentView.textsSpacing
    stackView.alignment = .leading // Horizontal alignment
    stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }()

  private lazy var closeButton: NSButton = {
    let button = NSButton(frame: .zero)
    button.bezelStyle = .circular
    button.isBordered = false
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(handleClose)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }()

  // Spacer view to push close button to the trailing edge
  private let spacerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
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

    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Theme.documentViewHeight))

    // Determine initial state
    documentState = determineDocumentState(documentInfo)

    setupView()
    syncUploadProgressBinding()
    updateUI()
    updateButtonState()

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

    // Create horizontal file info stack
    let fileSizeDownloadStack = NSStackView(views: [fileSizeLabel, actionButton])
    fileSizeDownloadStack.spacing = 8
    fileSizeDownloadStack.alignment = .centerY

    // Add elements to text stack
    textStackView.addArrangedSubview(fileNameLabel)
    textStackView.addArrangedSubview(fileSizeDownloadStack)

    fileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    fileNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    // Add icon to container first
    iconContainer.addSubview(iconView)
    iconContainer.addSubview(uploadProgressRing)
    iconContainer.addSubview(uploadCancelButton)
    iconContainer.addSubview(cancelIcon)
    iconContainer.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    iconContainer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    // Add elements to container stack
    containerStackView.addArrangedSubview(iconContainer)
    containerStackView.addArrangedSubview(textStackView)

    // Add close button if removeAction is provided
    if removeAction != nil {
      // Add spacer to push close button to the right
      containerStackView.addArrangedSubview(spacerView)

      containerStackView.addArrangedSubview(closeButton)
    }

    addSubview(containerStackView)

    // Make text stack view expandable
    textStackView.setContentHuggingPriority(.defaultLow, for: .horizontal)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: height),

      // Container stack constraints
      containerStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
      containerStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
      containerStackView.topAnchor.constraint(equalTo: topAnchor),
      containerStackView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // Icon container constraints to ensure fixed size
      iconContainer.widthAnchor.constraint(equalToConstant: Self.iconCircleSize),
      iconContainer.heightAnchor.constraint(equalToConstant: Self.iconCircleSize),

      // Icon constraints
      iconView.widthAnchor.constraint(equalToConstant: Self.iconCircleSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconCircleSize),
      iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

      // Upload ring
      uploadProgressRing.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      uploadProgressRing.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      uploadProgressRing.widthAnchor.constraint(equalToConstant: Self.uploadRingSize),
      uploadProgressRing.heightAnchor.constraint(equalToConstant: Self.uploadRingSize),

      uploadCancelButton.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      uploadCancelButton.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      uploadCancelButton.widthAnchor.constraint(equalToConstant: Self.uploadCancelButtonSize),
      uploadCancelButton.heightAnchor.constraint(equalToConstant: Self.uploadCancelButtonSize),

      // Cancel
      cancelIcon.widthAnchor.constraint(equalToConstant: Self.iconCircleSize),
      cancelIcon.heightAnchor.constraint(equalToConstant: Self.iconCircleSize),
      cancelIcon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      cancelIcon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

      // Make sure the download button doesn't grow too much
      actionButton.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
    ])

    if removeAction != nil {
      // Close button should have high hugging priority
      closeButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

      NSLayoutConstraint.activate([
        // Close button constraints
        closeButton.widthAnchor.constraint(equalToConstant: 24),
        closeButton.heightAnchor.constraint(equalToConstant: 24),
      ])
    }

    // Add gesture recognizer to cancel icon
    let tapGesture = NSClickGestureRecognizer(target: self, action: #selector(cancelDownload))
    cancelIcon.addGestureRecognizer(tapGesture)
    cancelIcon.isEnabled = true

    // Add gesture recognizers to icon and filename so they behave like the primary action button
    let iconTapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleIconOrNameClick))
    iconContainer.addGestureRecognizer(iconTapGesture)

    let nameTapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleIconOrNameClick))
    fileNameLabel.addGestureRecognizer(nameTapGesture)
    fileNameLabel.isEnabled = true
  }

  private func updateUI() {
    fileNameLabel.stringValue = documentInfo.document.fileName ?? "Unknown File"
    updateButtonState()
    updateIconForCurrentState()
  }

  /// Update the icon to match the current document state and theme
  private func updateIconForCurrentState() {
    iconView.contentTintColor = white ? .white : .secondaryLabelColor

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
    cancelIcon.contentTintColor = white ? .white : NSColor.systemBlue
    uploadCancelButton.contentTintColor = white ? .white : NSColor.systemBlue
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
        actionButton.isHidden = false
        fileSizeLabel.stringValue = FileHelpers.formatFileSize(UInt64(documentInfo.document.size ?? 0))
        actionButton.title = "Show in Finder"
        actionButton.contentTintColor = white ? .white : NSColor.systemBlue
        updateIconForCurrentState()

      case .needsDownload:
        // Show download button
        iconView.isHidden = false
        uploadProgressRing.isHidden = true
        uploadCancelButton.isHidden = true
        cancelIcon.isHidden = true
        actionButton.isHidden = false
        fileSizeLabel.stringValue = FileHelpers.formatFileSize(UInt64(documentInfo.document.size ?? 0))
        actionButton.title = "Download"
        actionButton.contentTintColor = white ? .white : NSColor.controlAccentColor
        updateIconForCurrentState()

      case let .downloading(bytesReceived, totalBytes):
        // Show download progress
        iconView.isHidden = true
        uploadProgressRing.isHidden = true
        uploadCancelButton.isHidden = true
        cancelIcon.isHidden = false
        actionButton.isHidden = true

        // Ensure cancel icon matches the current bubble color scheme
        cancelIcon.contentTintColor = white ? .white : NSColor.systemBlue
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
        actionButton.isHidden = true
        uploadProgressRing.setProgress(0)
        fileSizeLabel.stringValue = "Processing"

      case let .uploading(bytesSent, totalBytes):
        iconView.isHidden = true
        cancelIcon.isHidden = true
        uploadProgressRing.isHidden = false
        uploadCancelButton.isHidden = false
        actionButton.isHidden = true
        let fractionCompleted = totalBytes > 0 ? CGFloat(Double(bytesSent) / Double(totalBytes)) : 0
        uploadProgressRing.setProgress(fractionCompleted)
        fileSizeLabel.stringValue = uploadProgressLabel(bytesSent: bytesSent, totalBytes: totalBytes)
    }
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

  private func downloadAction() {
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
          self.autoSaveDownloadedFileIfNeeded(sourceURL: fileURL)
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
      downloadAction()

    default:
      break
    }
  }

  deinit {
    stopMonitoringProgress()
    clearUploadProgressBinding(resetState: true)
  }

  @objc private func handleClose() {
    removeAction?()
  }

  @objc private func handleIconOrNameClick() {
    switch documentState {
    case .locallyAvailable:
      showInFinder()
    case .needsDownload:
      downloadAction()
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
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
      return .downloading(bytesReceived: 0, totalBytes: Int64(documentInfo.document.size ?? 0))
    }

    return .needsDownload
  }

  private func pendingUploadDisplayState() -> DocumentPendingUploadDisplayState {
    DocumentPendingUploadDisplayState.resolve(
      isPendingMessage: isPendingOutgoingUploadMessage(),
      localDocumentId: documentInfo.document.id,
      progress: uploadProgressSnapshot
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
    downloadProgressSubscription = FileDownloader.shared.documentProgressPublisher(documentId: documentId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self else { return }

        Log.shared.info("Document \(documentId) progress: \(progress)")

        if progress.isComplete {
          documentState = .locallyAvailable
          stopMonitoringProgress()
        } else if let error = progress.error {
          Log.shared.error("Document download failed: \(error)")
          documentState = .needsDownload
          stopMonitoringProgress()
        } else if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(documentInfo.document.size ?? 0)
          )
        } else if progress.bytesReceived > 0 {
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(documentInfo.document.size ?? 0)
          )
        }
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
    uploadProgressBindingTask = Task { @MainActor [weak self] in
      guard let self else { return }

      let publisher = await FileUploader.shared.documentProgressPublisher(documentLocalId: documentLocalId)
      guard !Task.isCancelled, self.uploadProgressLocalId == documentLocalId else { return }

      self.uploadProgressBindingTask = nil
      self.uploadProgressSubscription = publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] progress in
          guard let self else { return }

          self.uploadProgressSnapshot = progress
          self.documentState = self.determineDocumentState(self.documentInfo)

          switch progress.stage {
          case .failed, .completed:
            self.clearUploadProgressBinding(resetState: false)
          case .processing, .uploading:
            break
          }
        }
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

//
extension DocumentView {
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

  private func autoSaveDownloadedFileIfNeeded(sourceURL: URL) {
    guard AppSettings.shared.autoSaveDownloadedFilesToDownloadsFolder else { return }
    do {
      _ = try ensureDocumentExistsInDownloads(sourceURL: sourceURL)
    } catch {
      Log.shared.error("Failed to auto-save downloaded file to Downloads", error: error)
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

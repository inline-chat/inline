import AppKit
import Cocoa
import Combine
import Foundation
import GRDB
import InlineKit
import InlineMacUI
import InlineUI
import Logger
import QuickLookUI

typealias DocumentPresentationPlan = DocumentFileLayoutPlan

extension DocumentFileLayoutPlan {
  static var fileNameFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }
  static var metadataFont: NSFont { .systemFont(ofSize: 12) }
  static var actionFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }
  static let controlTextPadding: CGFloat = 4

  static func preferredHeight(for documentInfo: DocumentInfo) -> CGFloat {
    hasThumbnail(documentInfo) ? thumbnailSize : Theme.documentViewHeight
  }

  static func preferredWidth(for documentInfo: DocumentInfo) -> CGFloat {
    let fileName = documentInfo.document.fileName ?? "Unknown File"
    let fileSize = FileHelpers.formatFileSize(UInt64(documentInfo.document.size ?? 0))
    let fileNameWidth = measuredWidth(fileName, font: fileNameFont)
    let fileSizeWidth = fileSizeDisplayWidth(fileSize)
    let finderWidth = fileSizeWidth + metadataSpacing + actionDisplayWidth("– Show in Finder")
    let downloadWidth = fileSizeWidth + metadataSpacing + actionDisplayWidth("– Download")
    let processingWidth = fileSizeDisplayWidth("Processing")
    let totalBytes = Int64(documentInfo.document.size ?? 0)
    let transferText = "\(formatTransferBytes(totalBytes)) / \(formatTransferBytes(totalBytes))"
    let transferWidth = fileSizeDisplayWidth(transferText)

    return preferredWidth(
      hasThumbnail: hasThumbnail(documentInfo),
      minimumWidth: Theme.documentViewWidth,
      fileNameWidth: fileNameWidth,
      metadataWidth: max(finderWidth, downloadWidth, processingWidth, transferWidth)
    )
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
    return make(
      media: .init(hasThumbnail: hasThumbnail(documentInfo), height: height, width: width),
      metadata: .init(
        fileSizeWidth: fileSizeWidth,
        actionWidth: actionWidth,
        allowsAction: allowsAction,
        showsClose: showsClose
      )
    )
  }

  private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }

  static func fileSizeDisplayWidth(_ text: String) -> CGFloat {
    measuredWidth(text, font: metadataFont) + controlTextPadding
  }

  static func actionDisplayWidth(_ title: String) -> CGFloat {
    measuredWidth(title, font: actionFont) + controlTextPadding
  }

  private static func hasThumbnail(_ documentInfo: DocumentInfo) -> Bool {
    documentInfo.thumbnail?.hasDisplayablePreview == true
  }

  private static func formatTransferBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
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
  private var actionColor: NSColor {
    white ? .white : Theme.accentColor
  }

  private var hasDocumentThumbnail: Bool {
    documentInfo.thumbnail?.hasDisplayablePreview == true
  }

  private var hasLoadedThumbnail: Bool {
    !thumbnailContainerView.isHidden && thumbnailView.displayedImage != nil
  }

  private var transferColor: NSColor {
    hasDocumentThumbnail ? .white : actionColor
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

  private lazy var thumbnailContainerView: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = DocumentPresentationPlan.thumbnailCornerRadius
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
    view.isHidden = true
    return view
  }()

  private lazy var thumbnailView: PlatformPhotoView = {
    let view = PlatformPhotoView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.photoContentMode = .aspectFit
    view.showsTinyThumbnailBackground = true
    view.showsLoadingPlaceholder = true
    return view
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
    button.action = #selector(cancelTransfer)
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
    label.font = DocumentPresentationPlan.fileNameFont
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
    label.font = DocumentPresentationPlan.metadataFont
    label.maximumNumberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.cell?.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    label.textColor = white ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
    return label
  }()

  private lazy var actionButton: NSButton = {
    let button = NSButton(title: "– Download", target: nil, action: #selector(actionButtonTapped))
    button.isBordered = false
    button.font = DocumentPresentationPlan.actionFont
    button.alignment = .left
    button.focusRingType = .none
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

    super.init(frame: NSRect(
      x: 0,
      y: 0,
      width: DocumentPresentationPlan.preferredWidth(for: documentInfo),
      height: height
    ))

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
    thumbnailContainerView.addSubview(thumbnailView)
    NSLayoutConstraint.activate([
      thumbnailView.leadingAnchor.constraint(equalTo: thumbnailContainerView.leadingAnchor),
      thumbnailView.trailingAnchor.constraint(equalTo: thumbnailContainerView.trailingAnchor),
      thumbnailView.topAnchor.constraint(equalTo: thumbnailContainerView.topAnchor),
      thumbnailView.bottomAnchor.constraint(equalTo: thumbnailContainerView.bottomAnchor),
    ])
    addSubview(thumbnailContainerView)
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
    thumbnailContainerView.addGestureRecognizer(thumbnailTapGesture)

    let nameTapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleIconOrNameClick))
    fileNameLabel.addGestureRecognizer(nameTapGesture)
    fileNameLabel.isEnabled = true
  }

  override func layout() {
    super.layout()
    let fileSizeWidth = DocumentPresentationPlan.fileSizeDisplayWidth(fileSizeLabel.stringValue)
    let actionWidth = DocumentPresentationPlan.actionDisplayWidth(actionButton.title)
    let plan = DocumentPresentationPlan.make(
      documentInfo: documentInfo,
      width: bounds.width,
      fileSizeWidth: fileSizeWidth,
      actionWidth: actionWidth,
      allowsAction: allowsActionForCurrentState,
      showsClose: removeAction != nil
    )

    thumbnailContainerView.frame = plan.mediaFrame
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
    thumbnailContainerView.isHidden = !hasDocumentThumbnail
    thumbnailView.setPhoto(
      hasDocumentThumbnail ? documentInfo.thumbnail : nil,
      reloadMessageOnFinish: fullMessage?.message
    )
    needsLayout = true
  }

  /// Update the icon to match the current document state and theme
  private func updateIconForCurrentState() {
    iconView.contentTintColor = hasDocumentThumbnail ? .white : (white ? .white : .secondaryLabelColor)

    switch documentState {
      case .needsDownload:
        iconView.image = NSImage(systemSymbolName: Symbol.download, accessibilityDescription: "Download")
      case .locallyAvailable:
        iconView.image = NSImage(systemSymbolName: fileTypeSymbolName(), accessibilityDescription: nil)
      case .downloading:
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
        actionButton.title = "– Show in Finder"
        actionButton.contentTintColor = actionColor
        updateIconForCurrentState()

      case .needsDownload:
        // Show download button
        iconView.isHidden = false
        uploadProgressRing.isHidden = true
        uploadCancelButton.isHidden = true
        cancelIcon.isHidden = true
        fileSizeLabel.stringValue = FileHelpers.formatFileSize(UInt64(documentInfo.document.size ?? 0))
        actionButton.title = "– Download"
        actionButton.contentTintColor = actionColor
        updateIconForCurrentState()

      case let .downloading(bytesReceived, totalBytes):
        iconView.isHidden = true
        uploadProgressRing.isHidden = false
        uploadCancelButton.isHidden = false
        cancelIcon.isHidden = true
        let fractionCompleted = totalBytes > 0 ? CGFloat(Double(bytesReceived) / Double(totalBytes)) : 0
        uploadProgressRing.setProgress(fractionCompleted)

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
    iconContainer.isHidden = hasDocumentThumbnail && isLocallyAvailable
    iconContainer.layer?.backgroundColor = if hasDocumentThumbnail {
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

  @objc private func cancelTransfer() {
    switch documentState {
    case .downloading:
      cancelDownload()
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

    if case .downloading = documentState {
      return
    }

    let documentId = documentInfo.id
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
      documentState = determineDocumentState(documentInfo)
      startMonitoringProgress()
      return
    }

    // Set initial downloading state
    documentState = .downloading(bytesReceived: 0, totalBytes: Int64(documentInfo.document.size ?? 0))

    // Start monitoring progress
    startMonitoringProgress()

    // Start the download
    let startedNativeDownload = ExperimentalFeatureFlags.nativeFileDownloadsEnabled
    FileDownloader.shared.downloadDocument(document: documentInfo, for: fullMessage.message) { [weak self] result in
      guard let self else { return }

      DispatchQueue.main.async {
        switch result {
        case let .success(fileURL):
          self.locallyAvailableFileURL = fileURL
          self.documentState = .locallyAvailable
          self.stopMonitoringProgress()
          if saveToDownloadsWhenFinished {
            self.saveDownloadedFileToDownloads(sourceURL: fileURL)
          }
        case let .failure(error):
          Log.shared.error("Document download failed: \(error)")
          self.documentState = .needsDownload
          self.stopMonitoringProgress()
          if !FileDownloader.isCancellation(error), startedNativeDownload {
            ToastCenter.shared.showError(
              "Native file download failed. Disable Native File Downloads to retry through CDN."
            )
          }
        }
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

  func appendContextMenuItems(to menu: NSMenu) {
    if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
      menu.addItem(.separator())
    }

    let state = determineDocumentState(documentInfo)
    switch state {
    case .locallyAvailable:
      menu.addItem(documentMenuItem(
        title: "Open Document",
        symbolName: "doc.text.magnifyingglass",
        action: #selector(openDocumentFromMenu)
      ))
      menu.addItem(documentMenuItem(
        title: "Show in Finder",
        symbolName: "folder",
        action: #selector(showDocumentInFinderFromMenu)
      ))
      menu.addItem(documentMenuItem(
        title: "Save Document As…",
        symbolName: "square.and.arrow.down",
        action: #selector(saveDocumentFromMenu)
      ))
    case .needsDownload:
      menu.addItem(documentMenuItem(
        title: "Download Document",
        symbolName: "arrow.down.circle",
        action: #selector(downloadDocumentFromMenu)
      ))
    case .downloading:
      menu.addItem(documentMenuItem(
        title: "Cancel Download",
        symbolName: "xmark.circle",
        action: #selector(cancelDocumentTransferFromMenu)
      ))
    case .uploadProcessing, .uploading:
      menu.addItem(documentMenuItem(
        title: "Cancel Upload",
        symbolName: "xmark.circle",
        action: #selector(cancelDocumentTransferFromMenu)
      ))
    }
  }

  private func documentMenuItem(title: String, symbolName: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
    return item
  }

  @objc private func openDocumentFromMenu() {
    openQuickLook()
  }

  @objc private func showDocumentInFinderFromMenu() {
    showInFinder()
  }

  @objc private func saveDocumentFromMenu() {
    saveDocumentAs()
  }

  @objc private func downloadDocumentFromMenu() {
    downloadAction(saveToDownloadsWhenFinished: true)
  }

  @objc private func cancelDocumentTransferFromMenu() {
    cancelTransfer()
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
    let previousDocumentId = self.documentInfo.id
    self.documentInfo = documentInfo
    if let fullMessage {
      self.fullMessage = fullMessage
    }
    if previousDocumentId != documentInfo.id {
      locallyAvailableFileURL = Self.localDocumentURL(for: documentInfo)
    } else if let refreshedURL = Self.localDocumentURL(for: documentInfo) {
      locallyAvailableFileURL = refreshedURL
    } else if !Self.fileExists(at: locallyAvailableFileURL) {
      locallyAvailableFileURL = nil
    }
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
    Self.localDocumentURL(for: documentInfo) != nil || Self.fileExists(at: locallyAvailableFileURL)
  }

  // MARK: - Progress Monitoring

  private func startMonitoringProgress() {
    downloadProgressSubscription?.cancel()

    Log.shared.debug("Starting progress subscription for document \(documentInfo.id)")

    let documentId = documentInfo.id
    if let progress = FileDownloader.shared.currentDocumentProgress(documentId: documentId) {
      applyDownloadProgress(progress, documentId: documentId)
    }

    downloadProgressSubscription = FileDownloader.shared.documentProgressPublisher(documentId: documentId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self else { return }

        Log.shared.trace("Document \(documentId) progress: \(progress)")
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
          let panel = QLPreviewPanel.shared()
    else {
      return
    }

    locallyAvailableFileURL = sourceURL
    window?.makeFirstResponder(self)
    panel.updateController()
    panel.reloadData()
    if !panel.isVisible {
      panel.makeKeyAndOrderFront(nil)
    } else {
      panel.orderFront(nil)
    }
  }

  private func showInFinder() {
    guard let sourceURL = currentLocalDocumentURL() else { return }
    let fileName = documentInfo.document.fileName ?? "Unknown File"
    Task { @MainActor in
      let result = await Task.detached(priority: .userInitiated) {
        Result { try DocumentExportFileSystem.ensureInDownloads(sourceURL: sourceURL, fileName: fileName) }
      }.value

      switch result {
      case let .success(destinationURL):
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
      case let .failure(error):
        Log.shared.error("Failed to reveal downloaded file in Finder", error: error)
        NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
      }
    }
  }

  private func saveDownloadedFileToDownloads(sourceURL: URL) {
    let fileName = documentInfo.document.fileName ?? "Unknown File"
    Task { @MainActor in
      let result = await Task.detached(priority: .utility) {
        Result { try DocumentExportFileSystem.ensureInDownloads(sourceURL: sourceURL, fileName: fileName) }
      }.value
      if case let .failure(error) = result {
        Log.shared.error("Failed to save downloaded file to Downloads", error: error)
      }
    }
  }

  private func saveDocumentAs() {
    guard let sourceURL = currentLocalDocumentURL(), let window else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = documentInfo.document.fileName ?? "Unknown File"
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let destinationURL = panel.url else { return }
      Task { @MainActor in
        let result = await Task.detached(priority: .userInitiated) {
          Result { try DocumentExportFileSystem.copyReplacing(sourceURL: sourceURL, destinationURL: destinationURL) }
        }.value
        switch result {
        case .success:
          NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        case let .failure(error):
          Log.shared.error("Failed to save document", error: error)
        }
      }
    }
  }

  private func currentLocalDocumentURL() -> URL? {
    Self.localDocumentURL(for: documentInfo) ?? Self.existingFileURL(locallyAvailableFileURL)
  }

  private static func localDocumentURL(for documentInfo: DocumentInfo) -> URL? {
    guard let localPath = documentInfo.document.localPath, !localPath.isEmpty else { return nil }
    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    return existingFileURL(cacheDirectory.appendingPathComponent(localPath))
  }

  private static func existingFileURL(_ url: URL?) -> URL? {
    guard fileExists(at: url) else { return nil }
    return url
  }

  private static func fileExists(at url: URL?) -> Bool {
    guard let url else { return false }
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
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
    let sourceView = hasLoadedThumbnail ? thumbnailContainerView : iconContainer
    let frameInWindow = sourceView.convert(sourceView.bounds, to: nil)
    return window?.convertToScreen(frameInWindow) ?? .zero
  }

  func previewPanel(
    _: QLPreviewPanel!,
    transitionImageFor _: QLPreviewItem!,
    contentRect _: UnsafeMutablePointer<NSRect>!
  ) -> Any! {
    thumbnailView.displayedImage ?? iconView.image
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

private enum DocumentExportFileSystem {
  static func ensureInDownloads(sourceURL: URL, fileName: String) throws -> URL {
    let downloadsURL = try downloadsDirectoryURL()
    let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
    let resolvedFileName = safeFileName.isEmpty ? "Unknown File" : safeFileName
    let exactDestinationURL = downloadsURL.appendingPathComponent(resolvedFileName)

    if let existingURL = try findExistingCopy(
      sourceURL: sourceURL,
      in: downloadsURL,
      fileName: resolvedFileName
    ) {
      return existingURL
    }

    let destinationURL = if FileManager.default.fileExists(atPath: exactDestinationURL.path) {
      downloadsURL.appendingPathComponent(uniqueFileName(resolvedFileName, in: downloadsURL))
    } else {
      exactDestinationURL
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  static func copyReplacing(sourceURL: URL, destinationURL: URL) throws {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
  }

  private static func downloadsDirectoryURL() throws -> URL {
    if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
      return url
    }
    throw CocoaError(.fileNoSuchFile)
  }

  private static func uniqueFileName(_ fileName: String, in directory: URL) -> String {
    let parsedURL = URL(fileURLWithPath: fileName)
    let pathExtension = parsedURL.pathExtension
    let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
    let baseName = parsedURL.deletingPathExtension().lastPathComponent
    let regex = try? NSRegularExpression(pattern: " \\((\\d+)\\)$")
    let range = NSRange(baseName.startIndex ..< baseName.endIndex, in: baseName)

    let rootName: String
    let initialCounter: Int
    if let match = regex?.firstMatch(in: baseName, range: range),
       let numberRange = Range(match.range(at: 1), in: baseName),
       let existingNumber = Int(baseName[numberRange]),
       let rootRange = Range(NSRange(location: 0, length: match.range.location), in: baseName)
    {
      rootName = String(baseName[rootRange])
      initialCounter = existingNumber + 1
    } else {
      rootName = baseName
      initialCounter = 1
    }

    var counter = initialCounter
    while true {
      let candidate = "\(rootName) (\(counter))\(extensionSuffix)"
      if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
        return candidate
      }
      counter += 1
    }
  }

  private static func findExistingCopy(sourceURL: URL, in directory: URL, fileName: String) throws -> URL? {
    let exactURL = directory.appendingPathComponent(fileName)
    if FileManager.default.fileExists(atPath: exactURL.path), sameContents(sourceURL, exactURL) {
      return exactURL
    }

    let contents = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    return contents.first { candidate in
      isGeneratedDownloadName(candidate.lastPathComponent, for: fileName) && sameContents(sourceURL, candidate)
    }
  }

  private static func isGeneratedDownloadName(_ candidateName: String, for originalFileName: String) -> Bool {
    let originalURL = URL(fileURLWithPath: originalFileName)
    let candidateURL = URL(fileURLWithPath: candidateName)
    guard candidateURL.pathExtension == originalURL.pathExtension else { return false }
    let root = NSRegularExpression.escapedPattern(for: originalURL.deletingPathExtension().lastPathComponent)
    guard let regex = try? NSRegularExpression(pattern: "^\(root) \\([0-9]+\\)$") else { return false }
    let candidateBase = candidateURL.deletingPathExtension().lastPathComponent
    let range = NSRange(candidateBase.startIndex ..< candidateBase.endIndex, in: candidateBase)
    return regex.firstMatch(in: candidateBase, range: range) != nil
  }

  private static func sameContents(_ sourceURL: URL, _ destinationURL: URL) -> Bool {
    do {
      let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
      let destinationAttributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
      let sourceSize = sourceAttributes[.size] as? UInt64 ?? 0
      let destinationSize = destinationAttributes[.size] as? UInt64 ?? 0
      guard sourceSize == destinationSize else { return false }

      if sourceSize < 10_000_000 {
        return try Data(contentsOf: sourceURL) == Data(contentsOf: destinationURL)
      }

      guard let sourceDate = sourceAttributes[.modificationDate] as? Date,
            let destinationDate = destinationAttributes[.modificationDate] as? Date
      else { return false }
      return abs(sourceDate.timeIntervalSince(destinationDate)) < 1
    } catch {
      return false
    }
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

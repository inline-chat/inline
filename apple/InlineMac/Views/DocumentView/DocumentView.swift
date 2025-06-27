import AppKit
import Cocoa
import Combine
import Foundation
import InlineKit
import Logger

class DocumentView: NSView {
  private var height = Theme.documentViewHeight
  private static var iconCircleSize: CGFloat = 36
  private static var iconSpacing: CGFloat = 8
  private static var textsSpacing: CGFloat = 2

  enum DocumentState: Equatable {
    case locallyAvailable
    case needsDownload
    case downloading(bytesReceived: Int64, totalBytes: Int64)
  }

  private var progressSubscription: AnyCancellable?
  private var isDownloading = false
  private var white = false

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
    imageView.image = NSImage(systemSymbolName: "document", accessibilityDescription: nil)
    imageView.contentTintColor = white ?
      .white :
      .secondaryLabelColor

    let config = NSImage.SymbolConfiguration(pointSize: 21, weight: .regular)
    imageView.symbolConfiguration = config

    return imageView
  }()

  private let cancelIcon: NSImageView = {
    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.wantsLayer = true
    imageView.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
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
    label.textColor = ThemeManager.shared.selectedTheme.primaryTextColor
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
    }
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

    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Theme.documentViewHeight))

    // Determine initial state
    documentState = determineDocumentState(documentInfo)

    setupView()
    updateUI()
    updateButtonState()

    // Start monitoring progress if download is active
    if case .downloading = documentState {
      startMonitoringProgress()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
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

    // Add gesture recognizers to icon and filename for showing in Finder
    let iconTapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleIconOrNameClick))
    iconView.addGestureRecognizer(iconTapGesture)
    iconView.isEnabled = true

    let nameTapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleIconOrNameClick))
    fileNameLabel.addGestureRecognizer(nameTapGesture)
    fileNameLabel.isEnabled = true
  }

  private func updateUI() {
    fileNameLabel.stringValue = documentInfo.document.fileName ?? "Unknown File"
    fileSizeLabel.stringValue = FileHelpers
      .formatFileSize(UInt64(documentInfo.document.size ?? 0))

    // Set appropriate icon based on file type
    if let mimeType = documentInfo.document.mimeType {
      var iconName = "document"

      if mimeType.hasPrefix("image/") {
        iconName = "photo"
      } else if mimeType.hasPrefix("video/") {
        iconName = "video"
      } else if mimeType.hasPrefix("audio/") {
        iconName = "music.note"
      } else if mimeType == "application/pdf" {
        iconName = "text.document"
      } else if mimeType == "application/zip" || mimeType == "application/x-rar-compressed" {
        iconName = "shippingbox"
      }

      iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
    } else if let fileName = documentInfo.document.fileName,
              let fileExtension = fileName.components(separatedBy: ".").last?.lowercased()
    {
      // Fallback to extension-based icon if mime type is not available
      var iconName = "doc.circle.fill"

      switch fileExtension {
        case "pdf":
          iconName = "document"
        case "jpg", "jpeg", "png", "gif", "heic":
          iconName = "photo"
        case "mp4", "mov", "avi":
          iconName = "video"
        case "mp3", "wav", "aac":
          iconName = "music.note"
        case "zip", "rar", "7z":
          iconName = "shippingbox"
        case "doc", "docx":
          iconName = "text.document"
        case "xls", "xlsx":
          iconName = "chart.pie"
        case "ppt", "pptx":
          iconName = "videoprojector"
        default:
          iconName = "document"
      }

      iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
    }
  }

  private func updateButtonState() {
    switch documentState {
      case .locallyAvailable:
        // Show normal document view
        iconView.isHidden = false
        cancelIcon.isHidden = true
        actionButton.isHidden = false
        fileSizeLabel.stringValue = FileHelpers.formatFileSize(UInt64(documentInfo.document.size ?? 0))
        actionButton.title = "Show in Finder"
        actionButton.contentTintColor = white ? .white : NSColor.systemBlue

      case .needsDownload:
        // Show download button
        iconView.isHidden = false
        cancelIcon.isHidden = true
        actionButton.isHidden = false
        fileSizeLabel.stringValue = FileHelpers.formatFileSize(UInt64(documentInfo.document.size ?? 0))
        actionButton.title = "Download"
        actionButton.contentTintColor = white ? .white : NSColor.controlAccentColor

      case let .downloading(bytesReceived, totalBytes):
        // Show download progress
        iconView.isHidden = true
        cancelIcon.isHidden = false
        actionButton.isHidden = true

        // Format the progress text
        let downloadedStr = FileHelpers.formatFileSize(UInt64(bytesReceived))
        let totalStr = FileHelpers.formatFileSize(UInt64(totalBytes))
        fileSizeLabel.stringValue = "\(downloadedStr) / \(totalStr)"
    }
  }

  // MARK: - Actions

  @objc private func cancelDownload() {
    // Only cancel if we're in downloading state
    if case .downloading = documentState {
      // Cancel the download
      FileDownloader.shared.cancelDocumentDownload(documentId: documentInfo.document.documentId)

      // Reset state
      documentState = .needsDownload

      // Clean up subscription
      progressSubscription = nil
    }
  }

  private func downloadAction() {
    guard let fullMessage else {
      Log.shared.warning("Cannot download document without a message")
      return
    }

    // Check if download is already in progress by subscribing to progress
    let documentId = documentInfo.document.documentId

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
        case .success:
          break
        // Success - refresh document info
        // refreshDocumentInfo()
        case let .failure(error):
          Log.shared.error("Document download failed: \(error)")
          documentState = .needsDownload
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
    // Only cancel the subscription, not the download
    progressSubscription?.cancel()
    progressSubscription = nil
  }

  @objc private func handleClose() {
    removeAction?()
  }

  @objc private func handleIconOrNameClick() {
    // Only show in Finder if the file is locally available
    if case .locallyAvailable = documentState {
      showInFinder()
    }
  }

  func update(with documentInfo: DocumentInfo) {
    // Update document info
    self.documentInfo = documentInfo

    // Check if the document is already downloaded
    if documentInfo.document.localPath != nil {
      documentState = .locallyAvailable
      updateUI()
      return
    }

    // Set initial state
    documentState = determineDocumentState(documentInfo)
    updateUI()

    // Start monitoring if downloading
    if case .downloading = documentState {
      startMonitoringProgress()
    } else {
      // Cancel subscription if not downloading
      progressSubscription?.cancel()
      progressSubscription = nil
    }
  }

  // Method to manually set the state
  func setState(_ state: DocumentState) {
    documentState = state
  }

  // MARK: - Document State Management

  private func determineDocumentState(_ documentInfo: DocumentInfo) -> DocumentState {
    // First check if the file exists locally
    if isDocumentAvailableLocally() {
      return .locallyAvailable
    }

    // Then check if a download is in progress
    let documentId = documentInfo.document.documentId
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
      // A download is active, start with 0 progress
      return .downloading(bytesReceived: 0, totalBytes: Int64(documentInfo.document.size ?? 0))
    }

    // Otherwise, the document needs to be downloaded
    return .needsDownload
  }

  private func isDocumentAvailableLocally() -> Bool {
    guard let localPath = documentInfo.document.localPath else {
      return false
    }

    return true

    // Too agressive
    // Check if the file actually exists
//    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
//    let fileURL = cacheDirectory.appendingPathComponent(localPath)
//    return FileManager.default.fileExists(atPath: fileURL.path)
  }

  // MARK: - Progress Monitoring

  private func startMonitoringProgress() {
    // Cancel any existing subscription
    progressSubscription?.cancel()

    Log.shared.info("Starting progress subscription for document \(documentInfo.document.documentId)")

    // Start a new subscription
    let documentId = documentInfo.id
    progressSubscription = FileDownloader.shared.documentProgressPublisher(documentId: documentId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self else { return }

        Log.shared.info("Document \(documentId) progress: \(progress)")

        if progress.isComplete {
          // Download completed - refresh document info
          // self.refreshDocumentInfo()
        } else if let error = progress.error {
          // Download failed
          Log.shared.error("Document download failed: \(error)")
          documentState = .needsDownload
        } else if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
          // Download is active - update progress
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(documentInfo.document.size ?? 0)
          )
        } else if progress.bytesReceived > 0 {
          // We have progress but no active task - might be completing
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(documentInfo.document.size ?? 0)
          )
        }
      }
  }
}

//
extension DocumentView {
  private func showInFinder() {
    guard let localPath = documentInfo.document.localPath else { return }

    // Get the source file URL
    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    let sourceURL = cacheDirectory.appendingPathComponent(localPath)

    // Get the Downloads directory
    let fileManager = FileManager.default
    let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    // Get the filename
    let fileName = documentInfo.document.fileName ?? "Unknown File"

    // Check if an exact match already exists in Downloads
    let potentialExistingFile = downloadsURL.appendingPathComponent(fileName)

    if fileManager.fileExists(atPath: potentialExistingFile.path) {
      // File with same name exists in Downloads, check if it's the same file
      if hasSameContent(sourceURL: sourceURL, destinationURL: potentialExistingFile) {
        // It's the same file, just reveal it
        NSWorkspace.shared.activateFileViewerSelecting([potentialExistingFile])
        return
      } else {
        // It's a different file with the same name, create a unique name
        let uniqueFileName = createUniqueFileName(fileName, inDirectory: downloadsURL)
        let destinationURL = downloadsURL.appendingPathComponent(uniqueFileName)

        copyAndRevealFile(from: sourceURL, to: destinationURL, fallbackURL: sourceURL)
      }
    } else {
      // No file with same name exists in Downloads, copy it
      let destinationURL = downloadsURL.appendingPathComponent(fileName)

      copyAndRevealFile(from: sourceURL, to: destinationURL, fallbackURL: sourceURL)
    }
  }

  // Helper method to create a unique filename with sequential numbering
  private func createUniqueFileName(_ fileName: String, inDirectory directory: URL) -> String {
    let fileManager = FileManager.default

    // Split the filename into base name and extension
    let fileExtension = fileName.contains(".") ? "." + fileName.components(separatedBy: ".").last! : ""
    let baseName = fileName.contains(".") ? fileName.components(separatedBy: ".").dropLast()
      .joined(separator: ".") : fileName

    // Check if the base name already ends with a number in parentheses like "file (1)"
    let baseNameWithoutNumber: String
    let regex = try! NSRegularExpression(pattern: " \\((\\d+)\\)$", options: [])
    let range = NSRange(baseName.startIndex ..< baseName.endIndex, in: baseName)

    if let match = regex.firstMatch(in: baseName, options: [], range: range),
       let numberRange = Range(match.range(at: 1), in: baseName),
       let existingNumber = Int(baseName[numberRange])
    {
      // The filename already has a number, extract the base name without the number
      if let baseRange = Range(NSRange(location: 0, length: match.range.location), in: baseName) {
        baseNameWithoutNumber = String(baseName[baseRange])
      } else {
        baseNameWithoutNumber = baseName
      }

      // Start checking from the next number
      var counter = existingNumber + 1

      // Try incrementing numbers until we find an available filename
      while true {
        let newFileName = "\(baseNameWithoutNumber) (\(counter))\(fileExtension)"
        let newFilePath = directory.appendingPathComponent(newFileName).path

        if !fileManager.fileExists(atPath: newFilePath) {
          return newFileName
        }

        counter += 1
      }
    } else {
      // The filename doesn't have a number yet, start with (1)
      var counter = 1

      // Try incrementing numbers until we find an available filename
      while true {
        let newFileName = "\(baseName) (\(counter))\(fileExtension)"
        let newFilePath = directory.appendingPathComponent(newFileName).path

        if !fileManager.fileExists(atPath: newFilePath) {
          return newFileName
        }

        counter += 1
      }
    }
  }

  // Helper method to copy and reveal a file
  private func copyAndRevealFile(from sourceURL: URL, to destinationURL: URL, fallbackURL: URL) {
    let fileManager = FileManager.default

    do {
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    } catch {
      print("Error copying file: \(error)")
      // If copy fails, just show the original file
      NSWorkspace.shared.activateFileViewerSelecting([fallbackURL])
    }
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
      print("Error comparing files: \(error)")
      return false
    }
  }
}

import Combine
import Foundation
import InlineKit
import Logger
import QuickLook
import UIKit

class DocumentView: UIView {
  // MARK: - Properties
  
  let fullMessage: FullMessage?
  let outgoing: Bool

  enum DocumentState: Equatable {
    case locallyAvailable
    case needsDownload
    case downloading(bytesReceived: Int64, totalBytes: Int64)
  }

  private var progressSubscription: AnyCancellable?
  private var documentState: DocumentState = .needsDownload {
    didSet {
      updateUIForDocumentState()
    }
  }

  private var previewController: QLPreviewController?
  private var documentURL: URL?
  
  // Progress border
  private let progressLayer = CAShapeLayer()

  var documentInfo: DocumentInfo? {
    fullMessage?.documentInfo
  }

  var document: Document? {
    documentInfo?.document
  }

  var textColor: UIColor {
    outgoing ? .white : .label
  }

  var fileIconWrapperColor: UIColor {
    outgoing ? .white.withAlphaComponent(0.2) : ColorManager.shared.gray1
  }
  
  var progressBarColor: UIColor {
    outgoing ? .white : ColorManager.shared.selectedColor
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
    if let document = document {
      documentState = determineDocumentState(document)
    }
    
    updateUIForDocumentState()
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDocumentTappedNotification(_:)),
      name: Notification.Name("DocumentTapped"),
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

  func setupViews() {
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
    let circlePath = UIBezierPath(arcCenter: center,
                                  radius: CGFloat(circleRadius - 2),
                                  startAngle: -CGFloat.pi / 2,
                                  endAngle: 3 * CGFloat.pi / 2,
                                  clockwise: true)
    
    progressLayer.path = circlePath.cgPath
    progressLayer.strokeColor = progressBarColor.cgColor
    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.lineWidth = 2.0
    progressLayer.strokeEnd = 0.0
    
    fileIconButton.layer.addSublayer(progressLayer)
  }

  func setupContent() {
    // Colors
    fileNameLabel.textColor = textColor
    fileSizeLabel.textColor = textColor.withAlphaComponent(0.4)
    fileIconButton.backgroundColor = fileIconWrapperColor
    
    // Data
    fileNameLabel.text = document?.fileName ?? "Unknown File"
    fileSizeLabel.text = FileHelpers.formatFileSize(UInt64(document?.size ?? 0))
    
    // Set fixed width for fileSizeLabel to prevent layout shifts
    let maxSizeTextWidth = fileSizeLabel.intrinsicContentSize.width * 1.5
    fileSizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: maxSizeTextWidth).isActive = true

    updateFileIcon()
  }
  
  @objc func fileIconButtonTapped() {
    switch documentState {
    case .needsDownload:
      downloadFile()
    case .downloading:
      cancelDownload()
    case .locallyAvailable:
      openFile()
    }
  }
  
  @objc func viewTapped() {
    if case .locallyAvailable = documentState {
      openFile()
    } else {
      downloadFile()
    }
  }
  
  private func updateFileIcon() {
    switch documentState {
    case .needsDownload:
      iconView.image = UIImage(systemName: "arrow.down")
      iconView.tintColor = outgoing ? .white : ColorManager.shared.selectedColor
      
    case .downloading:
      
      iconView.image = UIImage(systemName: "xmark")
      iconView.tintColor = outgoing ? .white : ColorManager.shared.selectedColor
      
    case .locallyAvailable:
      // Show file type icon
      if let mimeType = document?.mimeType {
        var iconName = "document.fill"

        if mimeType.hasPrefix("image/") {
          iconName = "photo.fill"
        } else if mimeType.hasPrefix("video/") {
          iconName = "video.fill"
        } else if mimeType.hasPrefix("audio/") {
          iconName = "music.note.fill"
        } else if mimeType == "application/pdf" {
          iconName = "text.document.fill"
        } else if mimeType == "application/zip" || mimeType == "application/x-rar-compressed" {
          iconName = "shippingbox.fill"
        }

        iconView.image = UIImage(systemName: iconName)
        iconView.tintColor = outgoing ? .white : .systemGray
      } else if let fileName = document?.fileName,
                let fileExtension = fileName.components(separatedBy: ".").last?.lowercased()
      {
        // Fallback to extension-based icon if mime type is not available
        var iconName = "doc.circle.fill"

        switch fileExtension {
        case "pdf":
          iconName = "document.fill"
        case "jpg", "jpeg", "png", "gif", "heic":
          iconName = "photo.fill"
        case "mp4", "mov", "avi":
          iconName = "video.fill"
        case "mp3", "wav", "aac":
          iconName = "music.note.fill"
        case "zip", "rar", "7z":
          iconName = "shippingbox.fill"
        case "doc", "docx":
          iconName = "text.document.fill"
        case "xls", "xlsx":
          iconName = "chart.pie.fill"
        case "ppt", "pptx":
          iconName = "videoprojector.fill"
        default:
          iconName = "document.fill"
        }

        iconView.image = UIImage(systemName: iconName)
        iconView.tintColor = outgoing ? .white : .systemGray
      }
    }
  }

  private func updateUIForDocumentState() {
    UIView.performWithoutAnimation {
      switch documentState {
      case .locallyAvailable:
        
        progressLayer.strokeEnd = 0.0
        
        fileSizeLabel.text = FileHelpers.formatFileSize(UInt64(document?.size ?? 0))
        
      case .needsDownload:
        
        progressLayer.strokeEnd = 0.0
        fileSizeLabel.text = FileHelpers.formatFileSize(UInt64(document?.size ?? 0))
        
      case let .downloading(bytesReceived, totalBytes):
        let progress = Double(bytesReceived) / Double(totalBytes)
        
        progressLayer.strokeEnd = CGFloat(progress)
        
        let downloadedStr = FileHelpers.formatFileSize(UInt64(bytesReceived))
        let totalStr = FileHelpers.formatFileSize(UInt64(totalBytes))
        fileSizeLabel.text = "\(downloadedStr) / \(totalStr)"
      }
    }
    
    updateFileIcon()
  }

  func downloadFile() {
    guard let documentInfo = documentInfo, let document = document, let fullMessage = fullMessage else {
      return
    }
    
    if case .downloading = documentState {
      return
    }
    
    documentState = .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))
    
    startMonitoringProgress()
    
    FileDownloader.shared.downloadDocument(document: documentInfo, for: fullMessage.message) { [weak self] result in
      guard let self = self else { return }
      
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
      if let document = document {
        FileDownloader.shared.cancelDocumentDownload(documentId: document.documentId)
      }
      
      documentState = .needsDownload
      
      progressSubscription?.cancel()
      progressSubscription = nil
    }
  }

  func openFile() {
    guard
      let document = document,
      let localPath = document.localPath
    else {
      Log.shared.error("Cannot open document: No local path available")
      return
    }

    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    let fileURL = cacheDirectory.appendingPathComponent(localPath)

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      Log.shared.error("File does not exist at path: \(fileURL.path)")
      documentState = .needsDownload
      return
    }

    documentURL = fileURL

    let previewController = QLPreviewController()
    previewController.dataSource = self
    previewController.delegate = self
    self.previewController = previewController

    findViewController()?.present(previewController, animated: true)
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
    
    let documentId = document.documentId
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
      return .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))
    }
    
    return .needsDownload
  }
  
  // MARK: - Progress Monitoring
  
  private func startMonitoringProgress() {
    guard let document = document else { return }
    
    progressSubscription?.cancel()
    
    let documentId = document.documentId
    progressSubscription = FileDownloader.shared.documentProgressPublisher(documentId: documentId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        guard let self = self else { return }
        
        if progress.isComplete {
          self.documentState = .locallyAvailable
        } else if let error = progress.error {
          Log.shared.error("Document download failed:", error: error)
          self.documentState = .needsDownload
        } else if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
          self.documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(document.size ?? 0)
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

  deinit {
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
    label.lineBreakMode = .byTruncatingTail
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
    return documentURL != nil ? 1 : 0
  }
  
  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    return documentURL! as QLPreviewItem
  }
  
  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    previewController = nil
  }
}

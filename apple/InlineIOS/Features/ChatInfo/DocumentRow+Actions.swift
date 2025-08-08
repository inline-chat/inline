import Combine
import GRDB
import InlineKit
import Logger
import QuickLook
import SwiftUI

extension DocumentRow {
  func fileIconButtonTapped() {
    switch documentState {
      case .needsDownload:
        downloadFile()

      case .downloading:
        cancelDownload()

      case .locallyAvailable:
        openFile()
    }
  }

  func viewTapped() {
    guard !isBeingRemoved else { return }

    switch documentState {
      case .locallyAvailable:
        openFile()

      case .downloading:
        cancelDownload()

      case .needsDownload:
        downloadFile()
    }
  }

  // MARK: - File Operations

  func downloadFile() {
    let documentInfo = documentInfo
    let document = document

    // Prevent duplicate downloads
    if case .downloading = documentState {
      return
    }

    // Update UI state and start observing progress
    documentState = .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))
    startMonitoringProgress()

    let msg = documentMessage.message

    Log.shared.debug(
      "UI downloadFile tapped: docId=\(documentInfo.id) msgId=\(msg.id) fileName=\(document.fileName ?? "nil") size=\(document.size ?? -1) mime=\(document.mimeType ?? "nil") cdnUrl=\(document.cdnUrl ?? "nil")"
    )

    FileDownloader.shared.downloadDocument(document: documentInfo, for: msg) { result in
      DispatchQueue.main.async {
        Log.shared.debug("UI downloadFile completion: docId=\(documentInfo.id) result=\(result)")
        switch result {
          case .success:
            documentState = .locallyAvailable
          case let .failure(error):
            Log.shared.error("Document download failed:", error: error)
            documentState = .needsDownload
        }
      }
    }
  }

  func cancelDownload() {
    if case .downloading = documentState {
      FileDownloader.shared.cancelDocumentDownload(documentId: documentInfo.id)

      documentState = .needsDownload
      progressSubscription?.cancel()
      progressSubscription = nil
    }
  }

  func openFile() {
    Log.shared.debug("📄 openFile() called")

    let document = document
    guard let localPath = document.localPath else {
      Log.shared.error("📄 Cannot open document: No local path available")
      return
    }

    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    let fileURL = cacheDirectory.appendingPathComponent(localPath)

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      Log.shared.error("📄 File does not exist at path: \(fileURL.path)")
      documentState = .needsDownload
      return
    }

    documentURL = fileURL

    if QLPreviewController.canPreview(fileURL as QLPreviewItem) {
      Log.shared.debug("📄 Using QuickLook for preview")
      showingQuickLook = true
    } else {
      Log.shared.debug("📄 QuickLook can't preview - showing share options")
      // Use UIDocumentInteractionController for unsupported files
      showShareMenu(for: fileURL)
    }
  }

  private func showShareMenu(for url: URL) {
    // Find the root view controller to present from
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let rootViewController = window.rootViewController
    else {
      Log.shared.error("📄 Cannot find root view controller for share menu")
      return
    }

    // Create and store the interaction controller to keep it alive while the sheet is shown
    docInteractionController = UIDocumentInteractionController(url: url)
    guard let controller = docInteractionController else {
      Log.shared.error("📄 Failed to initialize UIDocumentInteractionController")
      return
    }

    // Present share menu
    let rect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
    if !controller.presentOptionsMenu(from: rect, in: rootViewController.view, animated: true) {
      Log.shared.error("📄 Failed to present share menu")
    }
  }

  func showDocumentError(_ message: String) {
    alertMessage = message
    showingAlert = true
  }

  // MARK: - Document State Management

  func determineDocumentState(_ document: Document) -> DocumentState {
    if let localPath = document.localPath {
      let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
      let fileURL = cacheDirectory.appendingPathComponent(localPath)

      if FileManager.default.fileExists(atPath: fileURL.path) {
        documentURL = fileURL
        return .locallyAvailable
      }
    }

    let documentInfo = documentInfo
    let documentId = documentInfo.id
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
      // Try to get current progress from FileDownloader instead of resetting to 0
      // This will be updated immediately by startMonitoringProgress() if needed
      return .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))
    }

    return .needsDownload
  }

  // MARK: - Progress Monitoring

  func startMonitoringProgress() {
    progressSubscription?.cancel()

    let documentId = documentInfo.id
    progressSubscription = FileDownloader.shared.documentProgressPublisher(documentId: documentId)
      .receive(on: DispatchQueue.main)
      .sink { progress in
        Log.shared.debug("📄 Document \(documentId) progress: \(progress)")

        if progress.isComplete {
          documentState = .locallyAvailable
        } else if let error = progress.error {
          Log.shared.error("Document download failed:", error: error)
          documentState = .needsDownload
        } else if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(document.size ?? 0)
          )
        } else if progress.bytesReceived > 0 {
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(document.size ?? 0)
          )
        }
      }
  }

  func setupInitialState() {
    // Only update state if we're not already in a downloading state
    // This preserves download progress when the view reappears during scrolling
    if case .downloading = documentState {
      // Already downloading, preserve current state and restore progress monitoring
      startMonitoringProgress()
      return
    }

    documentState = determineDocumentState(document)
    if case .downloading = documentState {
      startMonitoringProgress()
    }
  }

  func cleanup() {
    progressSubscription?.cancel()
    progressSubscription = nil
  }
}

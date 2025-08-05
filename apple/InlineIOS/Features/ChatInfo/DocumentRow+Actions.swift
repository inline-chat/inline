
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
    guard let documentInfo,
          let document
    else {
      return
    }

    if case .downloading = documentState {
      return
    }

    documentState = .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))

    startMonitoringProgress()
    print("LET ME DOWNLOAD")
//    FileDownloader.shared.downloadDocument(document: documentInfo, for: fullMessage.message) { result in
//      DispatchQueue.main.async {
//        switch result {
//        case .success:
//          documentState = .locallyAvailable
//        case let .failure(error):
//          Log.shared.error("Document download failed:", error: error)
//          documentState = .needsDownload
//        }
//      }
//    }
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

  func openFile() {
    Log.shared.debug("📄 openFile() called")

    guard let document,
          let localPath = document.localPath
    else {
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

    // Check file extension to avoid QuickLook for problematic file types
    let fileExtension = fileURL.pathExtension.lowercased()
    let problematicExtensions = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx"]

    if problematicExtensions.contains(fileExtension) {
      Log.shared.debug("📄 File type .\(fileExtension) may cause QuickLook crashes - showing alert")
      showDocumentError("This document type may not preview correctly.")
      return
    }

    if QLPreviewController.canPreview(fileURL as QLPreviewItem) {
      Log.shared.debug("📄 Using QuickLook for preview")
      showingQuickLook = true
    } else {
      Log.shared.debug("📄 QuickLook can't preview this file type")
      showDocumentError("This document type is not supported for preview.")
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

    guard let documentInfo else { return .needsDownload }
    let documentId = documentInfo.id
    if FileDownloader.shared.isDocumentDownloadActive(documentId: documentId) {
      return .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))
    }

    return .needsDownload
  }

  // MARK: - Progress Monitoring

  func startMonitoringProgress() {
    guard let documentInfo else { return }

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
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(document?.size ?? 0)
          )
        } else if progress.bytesReceived > 0 {
          documentState = .downloading(
            bytesReceived: progress.bytesReceived,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : Int64(document?.size ?? 0)
          )
        }
      }
  }

  func setupInitialState() {
    if let document {
      documentState = determineDocumentState(document)
    }
  }

  func cleanup() {
    progressSubscription?.cancel()
    progressSubscription = nil
    NotificationCenter.default.removeObserver(self)
  }
}

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
    guard let documentInfo,
          let document
    else {
      return
    }

    // Prevent duplicate downloads
    if case .downloading = documentState {
      return
    }

    // Update UI state and start observing progress
    documentState = .downloading(bytesReceived: 0, totalBytes: Int64(document.size ?? 0))
    startMonitoringProgress()
    
    let msg = documentMessage?.message
    
    FileDownloader.shared.downloadDocument(document: documentInfo, for: msg) { result in
      DispatchQueue.main.async {
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
      // Try to get current progress from FileDownloader instead of resetting to 0
      // This will be updated immediately by startMonitoringProgress() if needed
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

  // MARK: - Notification Listeners

  func setupNotificationListeners() {
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("DocumentUploadStarted"),
      object: nil,
      queue: .main
    ) { notification in
      handleDocumentUploadStarted(notification)
    }

    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("DocumentUploadCompleted"),
      object: nil,
      queue: .main
    ) { notification in
      handleDocumentUploadCompleted(notification)
    }

    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("DocumentUploadFailed"),
      object: nil,
      queue: .main
    ) { notification in
      handleDocumentUploadFailed(notification)
    }

    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("MessageStatusChanged"),
      object: nil,
      queue: .main
    ) { notification in
      handleMessageStatusChanged(notification)
    }
  }

  func handleDocumentUploadStarted(_ notification: Notification) {
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
    // Note: We don't handle upload state in DocumentRow since it's for chat info display
  }

  func handleDocumentUploadCompleted(_ notification: Notification) {
    guard let documentId = notification.userInfo?["documentId"] as? Int64,
          let document,
          document.id == documentId
    else { return }

    Log.shared.debug("Document upload completed for document ID: \(documentId)")
    documentState = .locallyAvailable
  }

  func handleDocumentUploadFailed(_ notification: Notification) {
    guard let documentId = notification.userInfo?["documentId"] as? Int64,
          let document,
          document.id == documentId
    else { return }

    let error = notification.userInfo?["error"] as? Error
    Log.shared.error("Document upload failed for document ID: \(documentId)", error: error)
    documentState = .needsDownload
  }

  func handleMessageStatusChanged(_ notification: Notification) {
    // This is primarily for upload status changes in message views
    // DocumentRow in chat info doesn't need to handle this specifically
  }

  func setupInitialState() {
    // Only update state if we're not already in a downloading state
    // This preserves download progress when the view reappears during scrolling
    if case .downloading = documentState {
      // Already downloading, preserve current state and restore progress monitoring
      startMonitoringProgress()
      return
    }

    if let document {
      documentState = determineDocumentState(document)
      // If we determined we're downloading, start monitoring progress
      if case .downloading = documentState {
        startMonitoringProgress()
      }
    }
  }

  func cleanup() {
    progressSubscription?.cancel()
    progressSubscription = nil
    NotificationCenter.default.removeObserver(self)
  }
}

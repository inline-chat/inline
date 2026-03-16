import InlineKit
import Logger
import UIKit
import UniformTypeIdentifiers

extension ComposeView: UIDocumentPickerDelegate {
  // MARK: - UIDocumentPickerDelegate

  func presentFileManager() {
    let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    documentPicker.delegate = self
    documentPicker.allowsMultipleSelection = false

    attachmentFlowPresenter()?.present(documentPicker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }

    addFile(url)
  }

  func addFile(_ url: URL) {
    if isVideoFile(url) {
      addVideo(url)
      return
    }

    // Ensure we can access the file
    guard url.startAccessingSecurityScopedResource() else {
      Log.shared.error("Failed to access security-scoped resource for file: \(url)")
      return
    }

    defer {
      url.stopAccessingSecurityScopedResource()
    }

    do {
      let documentInfo = try FileCache.saveDocument(url: url)
      let mediaItem = FileMediaItem.document(documentInfo)
      let uniqueId = addAttachmentItem(mediaItem)

      Log.shared.debug("Added file attachment with uniqueId: \(uniqueId)")
      dismissAttachmentPickerIfPresented(animated: true)
    } catch {
      Log.shared.error("Failed to save document", error: error)

      // Show error to user
      DispatchQueue.main.async { [weak self] in
        self?.showFileError(error)
      }
    }
  }

  private func showFileError(_ error: Error) {
    let alert = UIAlertController(
      title: "File Error",
      message: "Failed to add file: \(error.localizedDescription)",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))

    attachmentFlowPresenter()?.present(alert, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    Log.shared.debug("Document picker was cancelled")
  }

  private func isVideoFile(_ url: URL) -> Bool {
    if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
      if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
        return true
      }
    }

    if let type = UTType(filenameExtension: url.pathExtension) {
      return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    return false
  }
}

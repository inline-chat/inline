import Auth
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

    guard let destinationPeer = peerId,
          let account = try? Auth.shared.handle.beginAccountMutation() else { return }

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let documentInfo = try await FileCache.saveDocumentWithThumbnail(url: url)
        try Auth.shared.handle.validateAccountMutation(account)
        guard self.peerId == destinationPeer else { return }
        let mediaItem = FileMediaItem.document(documentInfo)
        addAttachmentItem(mediaItem)

        textView.becomeFirstResponder()
        dismissAttachmentPickerIfPresented(animated: true)
      } catch {
        Log.shared.error("Failed to save document", error: error)
        guard self.peerId == destinationPeer,
              (try? Auth.shared.handle.validateAccountMutation(account)) != nil else { return }
        showFileError(error)
      }
    }
  }

  private func showFileError(_ error: Error) {
    let alert = UIAlertController(
      title: "File Error",
      message: "Failed to attach file: \(error.localizedDescription)",
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

import Auth
import InlineKit
import Logger
import UIKit
import UniformTypeIdentifiers

extension ComposeView: UIDocumentPickerDelegate {
  // MARK: - UIDocumentPickerDelegate

  func presentFileManager() {
    guard canAttachFileToCurrentMessage() else { return }
    // Import before the callback so async preparation never depends on a Files provider's URL lifetime.
    let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    documentPicker.delegate = self
    documentPicker.allowsMultipleSelection = false

    attachmentFlowPresenter()?.present(documentPicker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }

    addFile(url)
  }

  func addFile(_ url: URL) {
    guard canAttachFileToCurrentMessage() else { return }
    if isVideoFile(url) {
      addVideo(url)
      return
    }

    guard let destinationPeer = peerId, let destinationChat = chatId,
          let account = try? Auth.shared.handle.beginAccountMutation() else { return }
    stageDocumentAttachment(url) { [weak self] in
      self?.peerId == destinationPeer && self?.chatId == destinationChat &&
        (try? Auth.shared.handle.validateAccountMutation(account)) != nil
    }
  }

  @discardableResult
  func stageDocumentAttachment(
    _ url: URL,
    loadDocument: @escaping @MainActor (URL) async throws -> DocumentInfo = { try await FileCache.saveDocumentWithThumbnail(url: $0) },
    isCurrentDestination: @escaping @MainActor () -> Bool
  ) -> Task<Void, Never> {
    guard canAttachFileToCurrentMessage() else { return Task {} }
    // These video-named APIs own all pending media sends and removal; keep one owner for Files too.
    let pendingId = addPendingVideoAttachment()
    updatePendingVideoAttachmentThumbnail(pendingId, image: UIImage(systemName: "doc"))
    let hasAccess = url.startAccessingSecurityScopedResource()

    return Task { @MainActor [weak self] in
      defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
      guard let self else { return }
      do {
        let documentInfo = try await loadDocument(url)
        guard !isPendingVideoAttachmentCanceled(pendingId) else {
          finishPendingVideoAttachmentProcessing(pendingId)
          return
        }
        guard isCurrentDestination() else {
          cancelQueuedPendingVideoSend()
          completePendingVideoAttachments([pendingId])
          return
        }
        guard canAttachFileToCurrentMessage() else {
          cancelQueuedPendingVideoSend()
          completePendingVideoAttachments([pendingId])
          return
        }
        let mediaItem = FileMediaItem.document(documentInfo)
        addAttachmentItem(mediaItem)
        completePendingVideoAttachments([pendingId])

        textView.becomeFirstResponder()
        dismissAttachmentPickerIfPresented(animated: true)
      } catch {
        Log.shared.error("Failed to save document", error: error)
        guard !isPendingVideoAttachmentCanceled(pendingId) else {
          finishPendingVideoAttachmentProcessing(pendingId)
          return
        }
        cancelQueuedPendingVideoSend()
        completePendingVideoAttachments([pendingId])
        guard isCurrentDestination() else { return }
        showFileError(error)
      }
    }
  }

  func canAttachFileToCurrentMessage() -> Bool {
    guard let peerId, ChatState.shared.getState(peer: peerId).editingMessageId != nil else { return true }
    showFilesEditingFeedback(sending: false)
    return false
  }

  func showFilesEditingFeedback(sending: Bool) {
    ToastManager.shared.showToast(
      sending ? "Remove attachments before saving edits." : "Finish editing before attaching a file.",
      type: .error,
      systemImage: "paperclip"
    )
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

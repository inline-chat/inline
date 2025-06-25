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

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(documentPicker, animated: true)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }

    addFile(url)
  }

  func addFile(_ url: URL) {
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
      let uniqueId = mediaItem.getItemUniqueId()

      // Update state
      attachmentItems[uniqueId] = mediaItem

      Log.shared.debug("Added file attachment with uniqueId: \(uniqueId)")

      // Send immediately after adding the file
      DispatchQueue.main.async { [weak self] in
        self?.sendMessage()
      }
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

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(alert, animated: true)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    Log.shared.debug("Document picker was cancelled")
  }
}

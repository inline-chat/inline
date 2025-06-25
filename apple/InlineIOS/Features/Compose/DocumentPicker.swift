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

    Log.shared.debug("Selected file: \(url.lastPathComponent)")

    // TODO: Implement file attachment functionality
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    Log.shared.debug("Document picker was cancelled")
  }
}

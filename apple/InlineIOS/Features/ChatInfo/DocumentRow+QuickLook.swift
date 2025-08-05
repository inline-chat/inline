import QuickLook
import SwiftUI

/// A SwiftUI wrapper around `QLPreviewController` that previews a single local file.
struct QuickLookView: UIViewControllerRepresentable {
  let url: URL

  // MARK: - UIViewControllerRepresentable

  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
    // No dynamic updates required – file URL is immutable for the lifetime of the sheet.
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(url: url)
  }

  // MARK: - Coordinator

  final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    let url: URL
    init(url: URL) { self.url = url }

    // QLPreviewControllerDataSource
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
      url as QLPreviewItem
    }
  }
}

// Convenience bridge for theme colours used elsewhere in the file-group.
extension UIColor {
  var color: Color { Color(self) }
}

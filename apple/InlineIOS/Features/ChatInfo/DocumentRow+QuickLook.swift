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
    // Force reload the preview items when the controller is created
    controller.reloadData()
    return controller
  }

  func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
    // Update coordinator's URL and reload data if URL changed
    if context.coordinator.url != url {
      context.coordinator.url = url
      uiViewController.reloadData()
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(url: url)
  }

  // MARK: - Coordinator

  final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    var url: URL
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

import QuickLook
import SwiftUI
import UIKit

/// A SwiftUI wrapper around `QLPreviewController` that previews a single local file.
struct QuickLookView: UIViewControllerRepresentable {
  let url: URL

  // MARK: - UIViewControllerRepresentable

  func makeUIViewController(context: Context) -> UINavigationController {
    let previewController = QLPreviewController()
    previewController.dataSource = context.coordinator
    previewController.delegate = context.coordinator
    
    let navController = UINavigationController(rootViewController: previewController)
    return navController
  }

  func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
    // Update coordinator's URL and reload data if URL changed
    if context.coordinator.url != url {
      context.coordinator.url = url
      if let previewController = uiViewController.topViewController as? QLPreviewController {
        // Force a complete reload by refreshing the current preview item
        DispatchQueue.main.async {
          previewController.reloadData()
          previewController.refreshCurrentPreviewItem()
        }
      }
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

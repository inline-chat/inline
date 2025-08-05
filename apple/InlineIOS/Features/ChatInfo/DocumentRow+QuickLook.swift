import QuickLook
import SwiftUI

struct QuickLookView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
    // No updates needed
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(url: url)
  }

  class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    let url: URL

    init(url: URL) {
      self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
      1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
      url as QLPreviewItem
    }
  }
}

// MARK: - Extensions

extension UIColor {
  var color: Color {
    Color(self)
  }
}

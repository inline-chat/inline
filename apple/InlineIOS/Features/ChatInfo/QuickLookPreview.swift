import QuickLook
import SwiftUI
import Logger

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPresented: Bool
    
    func makeUIViewController(context: Context) -> UINavigationController {
        Log.shared.debug("📄 Creating QuickLook preview for URL: \(url.lastPathComponent)")
        
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        
        // Add Done button to navigation bar
        let doneButton = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.doneButtonTapped)
        )
        previewController.navigationItem.rightBarButtonItem = doneButton
        
        // Wrap in navigation controller to ensure toolbar appears
        let navigationController = UINavigationController(rootViewController: previewController)
        navigationController.navigationBar.prefersLargeTitles = false
        
        // Ensure proper modal presentation
        navigationController.modalPresentationStyle = .automatic
        
        return navigationController
    }
    
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // No updates needed - URL is set via data source
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: QuickLookPreview
        
        init(_ parent: QuickLookPreview) {
            self.parent = parent
        }
        
        // MARK: - QLPreviewControllerDataSource
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            Log.shared.debug("📄 QuickLook requesting preview item at index \(index) for \(parent.url.lastPathComponent)")
            return parent.url as QLPreviewItem
        }
        
        // MARK: - QLPreviewControllerDelegate
        
        func previewControllerWillDismiss(_ controller: QLPreviewController) {
            Log.shared.debug("📄 QuickLook preview will dismiss")
            parent.isPresented = false
        }
        
        // MARK: - Actions
        
        @objc func doneButtonTapped() {
            Log.shared.debug("📄 QuickLook Done button tapped")
            parent.isPresented = false
        }
    }
}
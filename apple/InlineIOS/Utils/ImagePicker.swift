import InlineKit
import InlineUI
import Logger
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers

struct ImagePicker: UIViewControllerRepresentable {
  var sourceType: UIImagePickerController.SourceType
  var completion: (UIImage) -> Void
    
  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = sourceType
    picker.delegate = context.coordinator
    return picker
  }
    
  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
    
  class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
    let parent: ImagePicker
        
    init(_ parent: ImagePicker) {
      self.parent = parent
    }
        
    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage {
        parent.completion(image)
      }
      picker.dismiss(animated: true)
    }
  }
}

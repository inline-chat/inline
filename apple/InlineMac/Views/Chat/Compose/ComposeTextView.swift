import AppKit
import UniformTypeIdentifiers

protocol ComposeTextViewDelegate: NSTextViewDelegate {
  func textViewDidPressReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool
  // Add new delegate method for image paste
  func textView(_ textView: NSTextView, didReceiveImage image: NSImage)
  func textView(_ textView: NSTextView, didReceiveFile url: URL)
  func textView(_ textView: NSTextView, didReceiveVideo url: URL)
}

class ComposeNSTextView: NSTextView {
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 {
      if event.modifierFlags.contains(.command) {
        if let delegate = delegate as? ComposeTextViewDelegate {
          if delegate.textViewDidPressCommandReturn(self) {
            return
          }
        }
      } else if !event.modifierFlags.contains(.shift) {
        if let delegate = delegate as? ComposeTextViewDelegate {
          if delegate.textViewDidPressReturn(self) {
            return
          }
        }
      }
    }
    super.keyDown(with: event)
  }

//  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
//    var types = newTypes
//    // Make sure image types are included
//    if !types.contains(.tiff) {
//      types.append(.tiff)
//    }
//    if !types.contains(.png) {
//      types.append(.png)
//    }
//    super.registerForDraggedTypes(types)
//  }

  // Override paste operation
//  override func paste(_ sender: Any?) {
//    let pasteboard = NSPasteboard.general
//
//    print(pasteboard.types)
//
//    // First check for files that are images
//    if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
//      for file in files {
//        let fileType = file.pathExtension.lowercased()
//        // Check if the file is an image
//        if ["png", "jpg", "jpeg", "gif", "heic"].contains(fileType) {
//          if let image = NSImage(contentsOf: file) {
//            // Notify delegate about image paste
//            if let delegate = delegate as? ComposeTextViewDelegate {
//              delegate.textView(self, didReceiveImage: image)
//              return
//            }
//          }
//        }
//      }
//    }
//
//    // Then check for direct image data in pasteboard
//    if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
//      // Notify delegate about image paste
//      if let delegate = delegate as? ComposeTextViewDelegate {
//        delegate.textView(self, didReceiveImage: image)
//        return
//      }
//    }
//
//    // If no image or no delegate, perform default paste
//    super.paste(sender)
//  }

  // MARK: - Drag and Drop

//  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
//    var types = newTypes
//    types.append(contentsOf: [.fileURL, .tiff, .png])
//    super.registerForDraggedTypes(types)
//  }
//
//  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
//    .copy
//  }
//
//  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
//    let pasteboard = sender.draggingPasteboard
//    // Reuse the same logic as in paste: method
//    return true
//  }
//

  // MARK: - Shared Logic For Drag And Paste

  private func handleImageInput(from pasteboard: NSPasteboard) -> Bool {
    // First check for files that are images
    if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
      var handled = false

      for file in files {
        let fileType = file.pathExtension.lowercased()
        // Check if the file is an image
        if ["png", "jpg", "jpeg", "gif", "heic"].contains(fileType) {
          if let image = NSImage(contentsOf: file) {
            // Notify delegate about image paste
            notifyDelegateAboutImage(image)
            handled = true
            continue
          }
        }

        // TODO: Video and other
        if ["mp4"].contains(fileType) {
          // Handle URL as file
          let _ = file.startAccessingSecurityScopedResource()
          notifyDelegateAboutVideo(file)
          file.stopAccessingSecurityScopedResource()
          handled = true
          continue
        }

        if file.isFileURL {
          // Handle URL as file
          let _ = file.startAccessingSecurityScopedResource()
          notifyDelegateAboutFile(file)
          file.stopAccessingSecurityScopedResource()
          handled = true
          continue
        }
      }

      return handled
    }

    // 2. Handle direct image data
    let imageTypes: [NSPasteboard.PasteboardType] = [
      .tiff, .png, NSPasteboard.PasteboardType("public.image"),
    ]

    if let bestType = pasteboard.availableType(from: imageTypes),
       let data = pasteboard.data(forType: bestType),
       let image = NSImage(data: data)
    {
      notifyDelegateAboutImage(image)
      return true
    }

    return false
  }

  private func notifyDelegateAboutImage(_ image: NSImage) {
    (delegate as? ComposeTextViewDelegate)?.textView(self, didReceiveImage: image)
  }

  private func notifyDelegateAboutFile(_ file: URL) {
    (delegate as? ComposeTextViewDelegate)?.textView(self, didReceiveFile: file)
  }

  private func notifyDelegateAboutVideo(_ url: URL) {
    (delegate as? ComposeTextViewDelegate)?.textView(self, didReceiveVideo: url)
  }

  // MARK: - Paste Handling

  override func paste(_ sender: Any?) {
    guard !handleImageInput(from: .general) else { return }
    super.paste(sender)
  }

  // MARK: - Drag & Drop Handling

  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
    var types = newTypes
    types.append(contentsOf: [.fileURL, .tiff, .png])
    super.registerForDraggedTypes(types)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let pasteboard = sender.draggingPasteboard
    return canHandlePasteboard(pasteboard) ? .copy : super.draggingEntered(sender)
  }

  private func canHandlePasteboard(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ||
      pasteboard.availableType(from: [.tiff, .png]) != nil
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let handled = handleImageInput(from: sender.draggingPasteboard)
    return handled || super.performDragOperation(sender)
  }
}

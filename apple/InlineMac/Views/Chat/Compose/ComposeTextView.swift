import AppKit

protocol ComposeTextViewDelegate: NSTextViewDelegate {
  func textViewDidPressReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool
  // Add new delegate method for image paste
  func textView(_ textView: NSTextView, didReceiveImage image: NSImage)
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
  
  // Override paste operation
  override func paste(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    
    // First check for files that are images
    if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
      for file in files {
        let fileType = file.pathExtension.lowercased()
        // Check if the file is an image
        if ["png", "jpg", "jpeg", "gif", "heic"].contains(fileType) {
          if let image = NSImage(contentsOf: file) {
            // Notify delegate about image paste
            if let delegate = delegate as? ComposeTextViewDelegate {
              delegate.textView(self, didReceiveImage: image)
              return
            }
          }
        }
      }
    }
    
    // Then check for direct image data in pasteboard
    if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
      // Notify delegate about image paste
      if let delegate = delegate as? ComposeTextViewDelegate {
        delegate.textView(self, didReceiveImage: image)
        return
      }
    }
    
    // If no image or no delegate, perform default paste
    super.paste(sender)
  }
}
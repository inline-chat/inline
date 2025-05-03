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

  private func logPasteboardTypes(_ pasteboard: NSPasteboard) {
    print("\n--- PASTEBOARD CONTENT ANALYSIS ---")

    // 1. Get all available types in the pasteboard
    if let types = pasteboard.types {
      print("📋 Available pasteboard types:")
      for type in types {
        print("• \(type.rawValue)")
      }
      print("")
    }

    // 2. Detailed analysis of image types
    print("🖼 IMAGE ANALYSIS:")
    let imageTypes: [NSPasteboard.PasteboardType] = [
      .tiff, .png,
      NSPasteboard.PasteboardType("public.jpeg"),
      NSPasteboard.PasteboardType("public.image"),
    ]

    for type in imageTypes {
      if let data = pasteboard.data(forType: type) {
        print("Found image data with type: \(type.rawValue)")

        if let image = NSImage(data: data) {
          print("Image dimensions: \(Int(image.size.width))×\(Int(image.size.height))")

          // Analyze representations
          for (index, rep) in image.representations.enumerated() {
            print("  Representation #\(index + 1):")

            print("  - Size: \(Int(rep.size.width))×\(Int(rep.size.height))")

            if let bitmapRep = rep as? NSBitmapImageRep {
              print("  - Bits per pixel: \(bitmapRep.bitsPerPixel)")
              print("  - Alpha: \(bitmapRep.hasAlpha ? "Yes" : "No")")

              print("  - Color space: \(bitmapRep.colorSpace.localizedName ?? "Unknown")")
            }
          }
        }
        print("")
      }
    }

    // 3. Check for file URLs (common when dragging from browser)
    print("📁 FILE URL ANALYSIS:")
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
      for (index, url) in urls.enumerated() {
        print("URL #\(index + 1): \(url.absoluteString)")

        if url.isFileURL {
          print("- This is a file URL")
          print("- File extension: \(url.pathExtension)")

          // Get file UTI
          if #available(macOS 11.0, *) {
            let fileType = UTType(filenameExtension: url.pathExtension)
            if let fileType {
              print("- UTI: \(fileType.identifier)")

              // Check if it's an image
              if fileType.conforms(to: .image) {
                print("- This is an image file")
              }
            }
          }

          // Get file attributes
          if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            print("- File size: \(attrs[.size] as? NSNumber ?? 0) bytes")
          }
        } else {
          print("- This is a web URL (not a file)")
        }
        print("")
      }
    }

    // 4. Check for HTML content (browsers often include this)
    print("🌐 HTML CONTENT ANALYSIS:")
    let htmlType = NSPasteboard.PasteboardType("public.html")
    if let htmlString = pasteboard.string(forType: htmlType) {
      print("HTML content found: \(htmlString.prefix(100))...")

      // Check for image tags in HTML
      if htmlString.contains("<img") {
        print("- HTML contains <img> tags")
      }
    } else {
      print("No HTML content found")
    }

    print("\n--- END OF ANALYSIS ---\n")
  }

  private func handleImageInput(from pasteboard: NSPasteboard) -> Bool {
    // Log pasteboard types for debugging
    logPasteboardTypes(pasteboard)

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

      if handled {
        return true
      }
    }

    // 2. Handle direct image data
    let imageTypes: [NSPasteboard.PasteboardType] = [
      .tiff,
      .png,
      NSPasteboard.PasteboardType("public.image"),
      NSPasteboard.PasteboardType("public.jpeg"),
      NSPasteboard.PasteboardType("image/png"),
      NSPasteboard.PasteboardType("image/jpeg"),
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
    types.append(contentsOf: [
      .fileURL,
      .tiff,
      .png,
      NSPasteboard.PasteboardType("public.image"),
      NSPasteboard.PasteboardType("public.jpeg"),
      NSPasteboard.PasteboardType("image/png"),
      NSPasteboard.PasteboardType("image/jpeg"),

    ])

    super.registerForDraggedTypes(types)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let pasteboard = sender.draggingPasteboard
    return canHandlePasteboard(pasteboard) ? .copy : super.draggingEntered(sender)
  }

  private func canHandlePasteboard(_ pasteboard: NSPasteboard) -> Bool {
    // Check for files
    if pasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
      return true
    }

    // Check for images from browsers
    let imageTypes: [NSPasteboard.PasteboardType] = [
      .tiff, .png, .html,
      NSPasteboard.PasteboardType("public.image"),
      NSPasteboard.PasteboardType("public.jpeg"),
      NSPasteboard.PasteboardType("image/png"),
      NSPasteboard.PasteboardType("image/jpeg"),
      NSPasteboard.PasteboardType("image/gif"),
      NSPasteboard.PasteboardType("image/webp"),
    ]

    return pasteboard.availableType(from: imageTypes) != nil
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let handled = handleImageInput(from: sender.draggingPasteboard)
    return handled || super.performDragOperation(sender)
  }
}

import AppKit
import Logger
import Nuke
import UniformTypeIdentifiers

protocol ComposeTextViewDelegate: NSTextViewDelegate {
  func textViewDidPressReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressArrowUp(_ textView: NSTextView) -> Bool
  func textViewDidPressArrowDown(_ textView: NSTextView) -> Bool
  func textViewDidPressTab(_ textView: NSTextView) -> Bool
  func textViewDidPressEscape(_ textView: NSTextView) -> Bool
  // Add new delegate method for image paste
  func textView(_ textView: NSTextView, didReceiveImage image: NSImage, url: URL?)
  func textView(_ textView: NSTextView, didReceiveFile url: URL)
  func textView(_ textView: NSTextView, didReceiveVideo url: URL)
  // Mention handling
  func textView(_ textView: NSTextView, didDetectMentionWith query: String, at location: Int)
  func textViewDidCancelMention(_ textView: NSTextView)
  // Focus handling
  func textViewDidGainFocus(_ textView: NSTextView)
  func textViewDidLoseFocus(_ textView: NSTextView)
}

class ComposeNSTextView: NSTextView {
  override func keyDown(with event: NSEvent) {
    // Handle return key
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

    // Handle arrow up key
    if event.keyCode == 126 {
      if let delegate = delegate as? ComposeTextViewDelegate {
        if delegate.textViewDidPressArrowUp(self) {
          return
        }
      }
    }

    // Handle arrow down key
    if event.keyCode == 125 {
      if let delegate = delegate as? ComposeTextViewDelegate {
        if delegate.textViewDidPressArrowDown(self) {
          return
        }
      }
    }

    // Handle tab key
    if event.keyCode == 48 {
      if let delegate = delegate as? ComposeTextViewDelegate {
        if delegate.textViewDidPressTab(self) {
          return
        }
      }
    }

    // Handle escape key
    if event.keyCode == 53 {
      if let delegate = delegate as? ComposeTextViewDelegate {
        if delegate.textViewDidPressEscape(self) {
          return
        }
      }
    }

    super.keyDown(with: event)
  }

  @discardableResult
  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      (delegate as? ComposeTextViewDelegate)?.textViewDidGainFocus(self)
    }
    return result
  }

  @discardableResult
  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      (delegate as? ComposeTextViewDelegate)?.textViewDidLoseFocus(self)
    }
    return result
  }

  public func handleAttachments(from pasteboard: NSPasteboard) -> Bool {
    let attachments = InlinePasteboard.findAttachments(from: pasteboard)

    for attachment in attachments {
      switch attachment {
        case let .image(image, url):
          notifyDelegateAboutImage(image, url)
        case let .video(url, _):
          notifyDelegateAboutVideo(url)
        case let .file(url, _):
          notifyDelegateAboutFile(url)
        case let .text(text):
          insertPlainText(text)
      }
    }

    return !attachments.isEmpty
  }

  private func notifyDelegateAboutImage(_ image: NSImage, _ url: URL? = nil) {
    (delegate as? ComposeTextViewDelegate)?.textView(self, didReceiveImage: image, url: url)
  }

  private func notifyDelegateAboutFile(_ file: URL) {
    (delegate as? ComposeTextViewDelegate)?.textView(self, didReceiveFile: file)
  }

  private func notifyDelegateAboutVideo(_ url: URL) {
    (delegate as? ComposeTextViewDelegate)?.textView(self, didReceiveVideo: url)
  }

  // MARK: - Paste Handling

  private func handlePasteboardContent(from pasteboard: NSPasteboard, fromPaste: Bool) -> Bool {
    // Try to handle attachments first
    if handleAttachments(from: pasteboard) {
      return true
    }

    // Handle rich text
    if handleRichTextPaste(from: pasteboard) {
      return true
    }

    return false
  }

  override func paste(_ sender: Any?) {
    if handlePasteboardContent(from: .general, fromPaste: true) {
      return
    }

    super.paste(sender)
  }

  private func handleRichTextPaste(from pasteboard: NSPasteboard) -> Bool {
    // Try to get plain text directly first (most efficient)
    if let plainText = pasteboard.string(forType: .string), !plainText.isEmpty {
      insertPlainText(plainText)
      return true
    }

    // Handle HTML content asynchronously to avoid blocking
    let htmlType = NSPasteboard.PasteboardType("public.html")
    if let htmlString = pasteboard.string(forType: htmlType), !htmlString.isEmpty {
      // Parse HTML asynchronously to avoid blocking UI
      Task { @MainActor in
        let plainText = await extractPlainTextFromHTML(htmlString)
        if !plainText.isEmpty {
          self.insertPlainText(plainText)
        }
      }
      return true
    }

    // Handle RTF content
    if let rtfData = pasteboard.data(forType: .rtf) {
      // Parse RTF asynchronously
      Task { @MainActor in
        if let attributedString = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
          let plainText = attributedString.string
          if !plainText.isEmpty {
            self.insertPlainText(plainText)
          }
        }
      }
      return true
    }

    return false
  }

  private func extractPlainTextFromHTML(_ html: String) async -> String {
    await Task.detached {
      // Use NSAttributedString to parse HTML safely
      guard let data = html.data(using: .utf8) else { return html }

      do {
        let attributedString = try NSAttributedString(
          data: data,
          options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
          ],
          documentAttributes: nil
        )
        return attributedString.string
      } catch {
        Log.shared.error("Failed to parse HTML: \(error)")
        // Simple regex fallback (more robust than before)
        return html.replacingOccurrences(
          of: "<[^>]*>",
          with: "",
          options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }.value
  }

  private func insertPlainText(_ inputText: String) {
    guard let textStorage else { return }

    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

    if text.isEmpty {
      return
    }

    // Get current selection
    let selectedRange = selectedRange()

    // Create attributed string with current typing attributes to ensure consistent styling
    let attributedText = NSAttributedString(string: text, attributes: typingAttributes)

    // Replace selected text with new attributed text
    textStorage.replaceCharacters(in: selectedRange, with: attributedText)

    // Update selection to end of inserted text using NSString length (not Swift String count)
    let newLocation = selectedRange.location + (text as NSString).length
    let newRange = NSRange(location: newLocation, length: 0)
    setSelectedRange(newRange)

    // Notify delegate of text change
    delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
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
    let handled = handlePasteboardContent(from: sender.draggingPasteboard, fromPaste: false)
    return handled || super.performDragOperation(sender)
  }

  // MARK: - Helper Methods

  private func loadImage(from url: URL) async -> NSImage? {
    do {
      // Create a request with proper options
      let request = ImageRequest(
        url: url,
        processors: [.resize(width: 1_280)], // Resize to reasonable size
        priority: .normal,
        options: []
      )

      // Try to get image from pipeline
      let response = try await ImagePipeline.shared.image(for: request)
      return response
    } catch {
      Log.shared.error("Failed to load image from URL: \(error.localizedDescription)")
      return nil
    }
  }
}

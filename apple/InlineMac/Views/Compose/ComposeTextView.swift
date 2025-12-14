import AppKit

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
      } else if !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.control),
                !event.modifierFlags.contains(.option)
      {
        if let delegate = delegate as? ComposeTextViewDelegate {
          // TODO: Improve this logic to only call return if actually return handler handles it
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

  public func handleAttachments(from pasteboard: NSPasteboard, includeText: Bool = true) -> Bool {
    let attachments = InlinePasteboard.findAttachments(from: pasteboard, includeText: includeText)

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

  override func paste(_ sender: Any?) {
    // Intercept non-text content (files/images/videos) and route through our attachment pipeline.
    if handleAttachments(from: .general, includeText: false) {
      return
    }

    // Use the native text system paste flow for correct undo/selection/IME behavior.
    super.pasteAsPlainText(sender)
  }

  private func insertPlainText(_ inputText: String, replacementRange: NSRange? = nil) {
    // Ignore whitespace-only pastes, but preserve spaces/newlines when content exists.
    guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
    let text = inputText.trimmingCharacters(in: .newlines)

    // Ensure we don't leak mention/code styles into the inserted text.
    updateTypingAttributesIfNeeded()

    let currentLength = (string as NSString).length
    var range = replacementRange ?? selectedRange()
    if range.location == NSNotFound {
      range = NSRange(location: currentLength, length: 0)
    } else {
      range.location = min(range.location, currentLength)
      range.length = min(range.length, currentLength - range.location)
    }

    insertText(text, replacementRange: range)
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
    // Prefer routing non-text content through our attachment pipeline.
    if handleAttachments(from: sender.draggingPasteboard, includeText: false) {
      return true
    }

    return super.performDragOperation(sender)
  }
}

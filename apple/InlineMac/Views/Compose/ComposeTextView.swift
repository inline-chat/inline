import AppKit
import InlineKit
import InlineMacUI
import InlineProtocol
import TextProcessing

protocol ComposeTextViewDelegate: NSTextViewDelegate {
  func textViewDidPressReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressOptionReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressArrowUp(_ textView: NSTextView, event: NSEvent) -> Bool
  func textViewDidPressArrowDown(_ textView: NSTextView, event: NSEvent) -> Bool
  func textViewDidPressArrowLeft(_ textView: NSTextView, event: NSEvent) -> Bool
  func textViewDidPressArrowRight(_ textView: NSTextView, event: NSEvent) -> Bool
  func textViewDidPressTab(_ textView: NSTextView) -> Bool
  func textViewDidPressEscape(_ textView: NSTextView) -> Bool
  func textViewDidChangeFormatting(_ textView: NSTextView)
  // Add new delegate method for image paste
  func textView(_ textView: NSTextView, didReceiveImage image: NSImage, url: URL?)
  func textView(_ textView: NSTextView, didReceiveFile url: URL)
  func textView(_ textView: NSTextView, didReceiveVideo url: URL)
  func textView(_ textView: NSTextView, didReceiveAnimatedImage url: URL)
  func textView(_ textView: NSTextView, didFailToPasteAttachment failure: PasteboardAttachmentFailure)
  // Mention handling
  func textView(_ textView: NSTextView, didDetectMentionWith query: String, at location: Int)
  func textViewDidCancelMention(_ textView: NSTextView)
  // Focus handling
  func textViewDidGainFocus(_ textView: NSTextView)
  func textViewDidLoseFocus(_ textView: NSTextView)
}

extension ComposeTextViewDelegate {
  func textViewDidPressOptionReturn(_ textView: NSTextView) -> Bool {
    false
  }
}

class ComposeNSTextView: NSTextView {
  private var isStrippingEmailLinks = false
  private var isHandlingKeyDown = false
  private let boldUndoActionName = "Bold"
  private let italicUndoActionName = "Italic"
  private let inlineCodeUndoActionName = "Inline Code"
  private let linkUndoActionName = "Make Link"
  var smartLinkPeer: InlineKit.Peer? {
    didSet { if oldValue != smartLinkPeer { resetPastedLinks() } }
  }
  var smartLinkEscapeAvailabilityDidChange: ((Bool) -> Void)?
  private lazy var pastedLinkSession = ComposePastedLinkSession(
    snapshot: { [weak self] in
      guard let self else { return nil }
      return (NSAttributedString(attributedString: attributedString()), selectedRange())
    },
    replace: { [weak self] range, replacement, selection, action in
      self?.replacePastedLink(range: range, replacement: replacement, selection: selection, action: action) ?? false
    },
    availabilityChanged: { [weak self] in self?.smartLinkEscapeAvailabilityDidChange?($0) }
  )

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { resetPastedLinks() }
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let actionModifiers = modifiers.intersection([.command, .control, .option, .shift])
    if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "b" {
      toggleBold(self)
      return
    }
    if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "i" {
      toggleItalic(self)
      return
    }
    if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "u" {
      toggleUnderline(self)
      return
    }
    if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" {
      toggleInlineCode(self)
      return
    }

    // Handle return key
    if event.keyCode == 36 {
      if actionModifiers == [.option] {
        if let delegate = delegate as? ComposeTextViewDelegate,
           delegate.textViewDidPressOptionReturn(self) {
          return
        }
      } else if event.modifierFlags.contains(.command) {
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
        if delegate.textViewDidPressArrowUp(self, event: event) {
          return
        }
      }
    }

    // Handle arrow down key
    if event.keyCode == 125 {
      if let delegate = delegate as? ComposeTextViewDelegate {
        if delegate.textViewDidPressArrowDown(self, event: event) {
          return
        }
      }
    }

    // Handle arrow left key
    if event.keyCode == 123 {
      if let delegate = delegate as? ComposeTextViewDelegate {
        if delegate.textViewDidPressArrowLeft(self, event: event) {
          return
        }
      }
    }

    // Handle arrow right key
    if event.keyCode == 124 {
      if let delegate = delegate as? ComposeTextViewDelegate {
        if delegate.textViewDidPressArrowRight(self, event: event) {
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

    isHandlingKeyDown = true
    defer { isHandlingKeyDown = false }
    super.keyDown(with: event)
  }

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    guard isHandlingKeyDown,
          let text = insertString as? String,
          let replacement = ComposeAutoPairEditing.insertionReplacement(
            in: string,
            selectedRange: selectedRange(),
            replacementRange: replacementRange,
            insertedText: text
          )
    else {
      super.insertText(insertString, replacementRange: replacementRange)
      return
    }

    applyAutoPairReplacement(replacement)
  }

  override func deleteBackward(_ sender: Any?) {
    if revertSmartLinkAtCaret() {
      return
    }
    guard let replacement = ComposeAutoPairEditing.deletionReplacement(
      in: string,
      selectedRange: selectedRange()
    ) else {
      super.deleteBackward(sender)
      return
    }

    applyAutoPairReplacement(replacement)
  }

  private func applyAutoPairReplacement(_ replacement: ComposeAutoPairEditing.Replacement) {
    if replacement.text.isEmpty, replacement.range.length == 0 {
      setSelectedRange(replacement.selectedRange)
      return
    }

    updateTypingAttributesIfNeeded()

    guard shouldChangeText(in: replacement.range, replacementString: replacement.text) else { return }

    guard let textStorage else {
      super.insertText(replacement.text, replacementRange: replacement.range)
      setSelectedRange(replacement.selectedRange)
      return
    }

    let attributed = attributedString(for: replacement, in: textStorage)
    textStorage.replaceCharacters(in: replacement.range, with: attributed)
    setSelectedRange(replacement.selectedRange)
    didChangeText()
  }

  private func attributedString(
    for replacement: ComposeAutoPairEditing.Replacement,
    in textStorage: NSTextStorage
  ) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: replacement.text, attributes: typingAttributes)

    if let preservedTextRange = replacement.preservedTextRange,
       NSMaxRange(preservedTextRange) <= attributed.length,
       NSMaxRange(replacement.range) <= textStorage.length
    {
      let preserved = textStorage.attributedSubstring(from: replacement.range)
      attributed.replaceCharacters(in: preservedTextRange, with: preserved)
    }

    return attributed
  }

  override func didChangeText() {
    super.didChangeText()
    stripEmailLinkAttributes()
    pastedLinkSession.validate()
  }

  override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
    guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else {
      return false
    }

    pastedLinkSession.willChange(range: affectedCharRange, replacement: replacementString ?? "")
    return true
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
    let result = InlinePasteboard.findAttachmentsResult(from: pasteboard, includeText: includeText)
    let attachments = result.attachments

    if let failure = preferredFailure(from: result.failures) {
      (delegate as? ComposeTextViewDelegate)?.textView(self, didFailToPasteAttachment: failure)
    }

    for attachment in attachments {
      switch attachment {
        case let .image(image, url):
          notifyDelegateAboutImage(image, url)
        case let .animatedImage(url):
          notifyDelegateAboutAnimatedImage(url)
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

  private func preferredFailure(from failures: [PasteboardAttachmentFailure]) -> PasteboardAttachmentFailure? {
    failures.first(where: { $0.isTelegramSource }) ?? failures.first
  }

  private func stripEmailLinkAttributes() {
    guard !isStrippingEmailLinks else { return }
    guard let textStorage else { return }

    isStrippingEmailLinks = true
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
      let urlString: String? = {
        if let url = value as? URL { return url.absoluteString }
        if let string = value as? String { return string }
        return nil
      }()

      guard let urlString, let url = URL(string: urlString) else { return }
      if url.scheme?.lowercased() == "mailto" {
        textStorage.removeAttribute(.link, range: range)
      }
    }
    isStrippingEmailLinks = false
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

  private func notifyDelegateAboutAnimatedImage(_ url: URL) {
    (delegate as? ComposeTextViewDelegate)?.textView(self, didReceiveAnimatedImage: url)
  }

  private func notifyDelegateAboutFormattingChange() {
    (delegate as? ComposeTextViewDelegate)?.textViewDidChangeFormatting(self)
  }

  @objc func toggleBold(_ sender: Any?) {
    let range = selectedRange()
    guard range.location != NSNotFound else { return }

    if range.length == 0 {
      toggleTypingAttributesBold()
      return
    }

    toggleBold(in: range)
  }

  @objc func toggleItalic(_ sender: Any?) {
    toggleFontTrait(
      actionName: italicUndoActionName,
      attribute: .italic,
      contains: { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) },
      convert: { font, enabled in
        enabled
          ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
          : NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
      }
    )
  }

  @objc func toggleUnderline(_ sender: Any?) { toggleStyle(.underline, actionName: "Underline") }
  @objc func toggleStrikethrough(_ sender: Any?) { toggleStyle(.strikethrough, actionName: "Strikethrough") }
  @objc func toggleHighlight(_ sender: Any?) { toggleStyle(.highlight, actionName: "Highlight") }

  private func toggleStyle(_ style: InlineTextStyle, actionName: String) {
    guard isEditable, selectedRange().location != NSNotFound else { return }
    let range = clampedRange(selectedRange())
    registerUndo(FormattingSnapshot(
      attributedString: NSAttributedString(attributedString: attributedString()),
      selectedRange: range, typingAttributes: typingAttributes, actionName: actionName
    ))
    if range.length == 0 {
      typingAttributes = style.settingEnabled(typingAttributes[style.marker] as? Bool != true, in: typingAttributes)
    } else if let textStorage {
      let enabled = !style.isEnabled(in: textStorage, range: range)
      textStorage.beginEditing()
      style.setEnabled(enabled, in: textStorage, range: range)
      textStorage.endEditing()
      setSelectedRange(range)
    }
    notifyDelegateAboutFormattingChange()
  }

  @objc func toggleInlineCode(_ sender: Any?) {
    let range = selectedRange()
    guard range.location != NSNotFound else { return }

    let snapshot = FormattingSnapshot(
      attributedString: NSAttributedString(attributedString: attributedString()),
      selectedRange: range,
      typingAttributes: typingAttributes,
      actionName: inlineCodeUndoActionName
    )
    registerUndo(snapshot)

    if range.length == 0 {
      let enabled = typingAttributes[.inlineCode] == nil
      var attributes = typingAttributes
      attributes[.inlineCode] = enabled ? true : nil
      attributes[.font] = enabled
        ? NSFont.monospacedSystemFont(ofSize: ComposeTextEditor.font.pointSize, weight: .regular)
        : ComposeTextEditor.font
      typingAttributes = attributes
    } else if let textStorage {
      let enabled = textStorage.attribute(.inlineCode, at: range.location, effectiveRange: nil) == nil
      textStorage.beginEditing()
      if enabled {
        textStorage.addAttribute(.inlineCode, value: true, range: range)
        textStorage.addAttribute(
          .font,
          value: NSFont.monospacedSystemFont(ofSize: ComposeTextEditor.font.pointSize, weight: .regular),
          range: range
        )
      } else {
        textStorage.removeAttribute(.inlineCode, range: range)
        textStorage.addAttribute(.font, value: ComposeTextEditor.font, range: range)
      }
      textStorage.endEditing()
      setSelectedRange(range)
    }
    notifyDelegateAboutFormattingChange()
  }

  override func paste(_ sender: Any?) {
    // Intercept non-text content (files/images/videos) and route through our attachment pipeline.
    if handleAttachments(from: .general, includeText: false) {
      return
    }

    if let range = selectedLinkTextRange(), let urlString = Self.linkURLString(from: .general) {
      applyLink(urlString, to: range)
      return
    }

    if let reference = ThreadReferencePasteboard.reference() {
      var attributes = defaultTypingAttributes
      attributes[.foregroundColor] = ComposeTextEditor.linkColor
      attributes[.threadLink] = ThreadLinkTarget.chatId(reference.chatId)
      attributes[.cursor] = NSCursor.pointingHand
      let linkedText = NSAttributedString(string: reference.label, attributes: attributes)
      insertText(linkedText, replacementRange: selectedRange())
      resetTypingAttributesToDefault()
      return
    }

    // Note(@Mo) Important: Temporarily disable rich-text paste entirely. We still rely on AppKit's native
    // plain-text paste pipeline for correct undo/redo, IME behavior, and selection handling, but we do not
    // allow any clipboard-provided styling to enter the compose view while we stabilize edge cases.
    let beforeRange = clampedRange(selectedRange())
    let beforeLength = (string as NSString).length

    resetTypingAttributesToDefault()
    super.pasteAsPlainText(sender)
    resetTypingAttributesToDefault()
    finishPastedText(replacedRange: beforeRange, previousLength: beforeLength)
    DispatchQueue.main.async { [weak self] in
      self?.resetTypingAttributesToDefault()
    }
  }

  private func finishPastedText(replacedRange: NSRange, previousLength: Int) {
    guard let textStorage else { return }
    let insertedLength = textStorage.length - (previousLength - replacedRange.length)
    guard insertedLength > 0 else { return }
    let range = NSRange(location: replacedRange.location, length: insertedLength)
    let links = ComposeLinkPaste.links(in: textStorage, range: range)
    for link in links {
      textStorage.addAttributes(linkAttributes(urlString: link.url.absoluteString), range: link.range)
    }
    resetTypingAttributesToDefault()
    if !links.isEmpty { didChangeText() }
    guard INUserSettings.current.compose.replacePastedLinksWithTitles else { return }
    let peer = smartLinkPeer
    pastedLinkSession.pasted(links: links) { url in
      try await ExternalResourceSearchClient.resolveLinkLabel(peer: peer, url: url)
    }
  }

  private func replacePastedLink(
    range: NSRange,
    replacement: NSAttributedString,
    selection: NSRange,
    action: String
  ) -> Bool {
    guard !hasMarkedText(), let textStorage else { return false }
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: replacement.string) else { return false }
    textStorage.replaceCharacters(in: range, with: replacement)
    setSelectedRange(selection)
    resetTypingAttributesToDefault()
    didChangeText()
    undoManager?.setActionName(action)
    breakUndoCoalescing()
    return true
  }

  func resetPastedLinks() { pastedLinkSession.reset() }

  @discardableResult
  func revertLatestSmartLink() -> Bool { pastedLinkSession.revertLatest() }

  private func revertSmartLinkAtCaret() -> Bool { pastedLinkSession.revertAtCaret() }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
    guard selectedLinkTextRange() != nil else { return menu }

    menu.addItem(.separator())

    let item = NSMenuItem(title: "Make Link...", action: #selector(makeLink(_:)), keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
    menu.addItem(item)

    return menu
  }

  @objc func makeLink(_ sender: Any?) {
    guard let range = selectedLinkTextRange() else { return }

    let prefill = existingLinkURLString(in: range) ?? Self.linkURLString(from: .general) ?? ""
    guard let urlString = promptForLinkURL(prefill: prefill) else { return }

    applyLink(urlString, to: range)
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(makeLink(_:)):
      selectedLinkTextRange() != nil
    case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleInlineCode(_:)),
         #selector(toggleUnderline(_:)), #selector(toggleStrikethrough(_:)), #selector(toggleHighlight(_:)):
      isEditable
    default:
      super.validateUserInterfaceItem(item)
    }
  }

  private func promptForLinkURL(prefill: String) -> String? {
    let input = NSTextField(string: prefill)
    input.placeholderString = "https://example.com"
    input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

    let alert = NSAlert()
    alert.messageText = "Make Link"
    alert.informativeText = "Enter a URL for the selected text."
    alert.addButton(withTitle: "Add Link")
    alert.addButton(withTitle: "Cancel")
    alert.accessoryView = input
    alert.window.initialFirstResponder = input

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    guard let urlString = ComposeLinkPaste.normalizedURLString(from: input.stringValue) else {
      NSSound.beep()
      return nil
    }

    return urlString
  }

  private func selectedLinkTextRange() -> NSRange? {
    let range = selectedRange()
    guard range.location != NSNotFound else { return nil }

    let safeRange = clampedRange(range)
    guard safeRange.length > 0 else { return nil }

    let selectedText = (string as NSString).substring(with: safeRange)
    guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    return safeRange
  }

  private func applyLink(_ urlString: String, to range: NSRange) {
    guard let textStorage else { return }

    let safeRange = clampedRange(range)
    guard safeRange.length > 0 else { return }
    pastedLinkSession.willChange(range: safeRange, replacement: (string as NSString).substring(with: safeRange))

    let snapshot = FormattingSnapshot(
      attributedString: NSAttributedString(attributedString: attributedString()),
      selectedRange: selectedRange(),
      typingAttributes: typingAttributes,
      actionName: linkUndoActionName
    )
    registerUndo(snapshot)

    textStorage.beginEditing()
    textStorage.removeAttribute(.emailAddress, range: safeRange)
    textStorage.removeAttribute(.phoneNumber, range: safeRange)
    textStorage.addAttributes(linkAttributes(urlString: urlString), range: safeRange)
    InlineTextStyle.reapply(to: textStorage)
    textStorage.endEditing()

    setSelectedRange(ComposeLinkPaste.selectionAfterApplyingLink(to: safeRange))
    resetTypingAttributesToDefault()
    notifyDelegateAboutFormattingChange()
  }

  private func existingLinkURLString(in range: NSRange) -> String? {
    guard let textStorage, range.location < textStorage.length else { return nil }

    let value = textStorage.attribute(.link, at: range.location, effectiveRange: nil)
    if let url = value as? URL {
      return ComposeLinkPaste.normalizedURLString(from: url)
    }

    if let string = value as? String {
      return ComposeLinkPaste.normalizedURLString(from: string)
    }

    return nil
  }

  private func linkAttributes(urlString: String) -> [NSAttributedString.Key: Any] {
    [
      .foregroundColor: ComposeTextEditor.linkColor,
      .link: urlString,
      .underlineStyle: 0,
      .cursor: NSCursor.pointingHand,
    ]
  }

  private func clampedRange(_ range: NSRange) -> NSRange {
    let length = (string as NSString).length
    let location = min(max(0, range.location), length)
    let safeLength = min(max(0, range.length), length - location)
    return NSRange(location: location, length: safeLength)
  }

  private static func linkURLString(from pasteboard: NSPasteboard) -> String? {
    if let string = pasteboard.string(forType: .string) {
      return ComposeLinkPaste.normalizedURLString(from: string)
    }

    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: false,
    ]
    let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
    for object in objects {
      if let url = object as? URL, let urlString = ComposeLinkPaste.normalizedURLString(from: url) {
        return urlString
      }

      if let url = object as? NSURL, let urlString = ComposeLinkPaste.normalizedURLString(from: url as URL) {
        return urlString
      }
    }

    return nil
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

  #if false
  // Temporarily disabled rich-text paste sanitization pipeline. Plain text paste is significantly more reliable
  // for AppKit undo/redo, IME composition, selection behavior, and for preventing unsupported styling leaks.
  private func readAttributedText(from pasteboard: NSPasteboard) -> (NSAttributedString, NSPasteboard.PasteboardType)? {
    // Prefer explicit rich text flavors (RTFD/RTF/HTML). Avoid `.string` here so we can preserve link targets.
    for type in Self.preferredRichTextTypes {
      guard pasteboard.availableType(from: [type]) == type else { continue }
      guard let data = pasteboard.data(forType: type) else { continue }

      var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
      if type == .html {
        options[.documentType] = NSAttributedString.DocumentType.html
        options[.characterEncoding] = String.Encoding.utf8.rawValue
      } else if type == .rtf {
        options[.documentType] = NSAttributedString.DocumentType.rtf
      } else if type == .rtfd {
        options[.documentType] = NSAttributedString.DocumentType.rtfd
      }

      if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
        return (stripAttachments(from: attributed), type)
      }
    }

    return nil
  }

  private func stripAttachments(from attributedString: NSAttributedString) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: attributedString)
    let fullRange = NSRange(location: 0, length: mutable.length)

    // Remove attachment characters entirely (e.g. HTML <img> becomes U+FFFC).
    var rangesToDelete: [NSRange] = []
    mutable.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
      if value != nil {
        rangesToDelete.append(range)
      }
    }

    for range in rangesToDelete.sorted(by: { $0.location > $1.location }) {
      mutable.deleteCharacters(in: range)
    }

    return mutable
  }

  private struct PasteSanitizationStats {
    var linksKept: Int = 0
    var linksDropped: Int = 0
    var linksKeptByScheme: [String: Int] = [:]
    var linksDroppedByScheme: [String: Int] = [:]
    var linksDroppedMultiline: Int = 0
    var linksDroppedLargeRange: Int = 0
    var linksKeptMaxRangeLen: Int = 0
    var listFixes: Int = 0
  }

  private func sanitizePastedAttributedString(_ input: NSAttributedString) -> (NSAttributedString, PasteSanitizationStats) {
    var stats = PasteSanitizationStats()
    let baseFont = font ?? NSFont.preferredFont(forTextStyle: .body)
    let baseTextColor = textColor ?? NSColor.labelColor

    var baseAttributes: [NSAttributedString.Key: Any] = [
      .font: baseFont,
      .foregroundColor: baseTextColor,
    ]

    if let paragraphStyle = typingAttributes[.paragraphStyle] {
      baseAttributes[.paragraphStyle] = paragraphStyle
    }

    let sanitized = NSMutableAttributedString(string: input.string, attributes: baseAttributes)
    let fullRange = NSRange(location: 0, length: sanitized.length)

    // Preserve links (skip mention links).
    input.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
      guard range.location != NSNotFound, range.length > 0, let value else { return }

      let linkString: String? = {
        if let url = value as? URL { return url.absoluteString }
        if let str = value as? String { return str }
        return nil
      }()

      let schemeForLogging = { (URL(string: linkString ?? "")?.scheme?.lowercased()) ?? "invalid" }

      guard let linkString, !linkString.isEmpty else {
        stats.linksDroppedByScheme["invalid", default: 0] += 1
        stats.linksDropped += 1
        return
      }

      guard isAllowedExternalLink(linkString) else {
        stats.linksDroppedByScheme[schemeForLogging(), default: 0] += 1
        stats.linksDropped += 1
        return
      }

      // Hardening: don't treat multi-line spans as links (common HTML export bug that makes whole blocks blue).
      let rangeText = (input.string as NSString).substring(with: range)
      if rangeText.contains("\n") {
        stats.linksDroppedMultiline += 1
        stats.linksDroppedByScheme[schemeForLogging(), default: 0] += 1
        stats.linksDropped += 1
        return
      }

      // Hardening: prevent extremely large linked ranges.
      let maxAllowedLinkRangeLength = 512
      if range.length > maxAllowedLinkRangeLength {
        stats.linksDroppedLargeRange += 1
        stats.linksDroppedByScheme[schemeForLogging(), default: 0] += 1
        stats.linksDropped += 1
        return
      }

      stats.linksKept += 1
      stats.linksKeptByScheme[schemeForLogging(), default: 0] += 1
      stats.linksKeptMaxRangeLen = max(stats.linksKeptMaxRangeLen, range.length)
      sanitized.addAttributes(linkAttributes(urlString: linkString), range: range)
    }

    // Preserve bold/italic by mapping traits onto our base font.
    input.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
      guard let sourceFont = value as? NSFont else { return }

      let traits = NSFontManager.shared.traits(of: sourceFont)
      let wantsBold = traits.contains(.boldFontMask)

      let attributesAtLocation = input.attributes(at: range.location, effectiveRange: nil)
      let wantsItalic = traits.contains(.italicFontMask) || attributesAtLocation[.italic] != nil

      guard wantsBold || wantsItalic else { return }

      let updatedFont = applyTraits(to: baseFont, bold: wantsBold, italic: wantsItalic)
      sanitized.addAttribute(.font, value: updatedFont, range: range)
      if wantsItalic {
        sanitized.addAttribute(.italic, value: true, range: range)
      }
    }

    // Some producers mark italic without an italic font; honor our custom italic attribute too.
    input.enumerateAttribute(.italic, in: fullRange, options: []) { value, range, _ in
      guard value != nil else { return }
      let updatedFont = applyTraits(to: baseFont, bold: false, italic: true)
      sanitized.addAttribute(.font, value: updatedFont, range: range)
      sanitized.addAttribute(.italic, value: true, range: range)
    }

    // Strip incidental underlines; restore only styles explicitly authored by Inline.
    if fullRange.length > 0 {
      sanitized.addAttribute(.underlineStyle, value: 0, range: fullRange)
      sanitized.removeAttribute(.underlineColor, range: fullRange)
    }
    InlineTextStyle.reapply(to: sanitized)

    // Normalize list markers that arrive as tab-delimited prefixes (common in RTF/HTML lists).
    stats.listFixes = normalizeTabDelimitedListMarkers(in: sanitized)

    return (sanitized, stats)
  }

  private func linkAttributes(urlString: String) -> [NSAttributedString.Key: Any] {
    [
      .foregroundColor: NSColor.linkColor,
      .link: urlString,
      .underlineStyle: 0,
      .cursor: NSCursor.pointingHand,
    ]
  }

  private func isAllowedExternalLink(_ urlString: String) -> Bool {
    LinkDetector.isSupportedLinkURLString(urlString)
  }

  private func applyTraits(to baseFont: NSFont, bold: Bool, italic: Bool) -> NSFont {
    var traits: NSFontTraitMask = []
    if bold { traits.insert(.boldFontMask) }
    if italic { traits.insert(.italicFontMask) }

    guard !traits.isEmpty else { return baseFont }

    // Try NSFontManager conversion first.
    if let converted = NSFontManager.shared.convert(baseFont, toHaveTrait: traits) as NSFont? {
      return converted
    }

    // Fallback: descriptor symbolic traits.
    var symbolic: NSFontDescriptor.SymbolicTraits = []
    if bold { symbolic.insert(.bold) }
    if italic { symbolic.insert(.italic) }
    let descriptor = baseFont.fontDescriptor.withSymbolicTraits(symbolic)
    if let viaDescriptor = NSFont(descriptor: descriptor, size: baseFont.pointSize) {
      return viaDescriptor
    }

    let safeSize = max(baseFont.pointSize, 12.0)
    if bold, !italic {
      return NSFont.boldSystemFont(ofSize: safeSize)
    }

    return NSFont.systemFont(ofSize: safeSize)
  }

  private func performNativePaste(
    with attributed: NSAttributedString,
    into pasteboard: NSPasteboard,
    sender: Any?
  ) -> Bool {
    // Avoid pasting whitespace-only content.
    guard attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return true }

    guard let rtf = try? attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    ) else {
      return false
    }

    let snapshot = snapshotPasteboard(pasteboard)
    defer { restorePasteboard(pasteboard, snapshot: snapshot) }

    pasteboard.clearContents()

    let item = NSPasteboardItem()
    item.setData(rtf, forType: .rtf)
    item.setString(attributed.string, forType: .string)

    guard pasteboard.writeObjects([item]) else { return false }

    // Reset typing attributes so we never leak unsupported formatting into pasted content.
    resetTypingAttributesForPaste()
    super.paste(sender)
    // Reset again after paste; AppKit can mutate `font`/`typingAttributes` during insertion.
    resetTypingAttributesForPaste()

    // Note(@Mo) Important: AppKit may update typing state asynchronously as part of paste/layout/selection.
    // Force-reset on the next runloop tick so we never leak producer formatting into subsequent typing.
    DispatchQueue.main.async { [weak self] in
      self?.resetTypingAttributesForPaste()
    }

    return true
  }

  private enum PasteboardRepresentation {
    case data(Data)
    case string(String)
    case propertyList(Any)
  }

  private struct PasteboardItemSnapshot {
    let representations: [(NSPasteboard.PasteboardType, PasteboardRepresentation)]
  }

  private struct PasteboardSnapshot {
    let items: [PasteboardItemSnapshot]
  }

  private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
    let items = (pasteboard.pasteboardItems ?? []).map { item in
      var reps: [(NSPasteboard.PasteboardType, PasteboardRepresentation)] = []
      reps.reserveCapacity(item.types.count)

      for type in item.types {
        if let data = item.data(forType: type) {
          reps.append((type, .data(data)))
        } else if let string = item.string(forType: type) {
          reps.append((type, .string(string)))
        } else if let plist = item.propertyList(forType: type) {
          reps.append((type, .propertyList(plist)))
        }
      }

      return PasteboardItemSnapshot(representations: reps)
    }

    return PasteboardSnapshot(items: items)
  }

  private func restorePasteboard(_ pasteboard: NSPasteboard, snapshot: PasteboardSnapshot) {
    pasteboard.clearContents()
    guard snapshot.items.isEmpty == false else { return }

    let items: [NSPasteboardItem] = snapshot.items.map { snap in
      let item = NSPasteboardItem()
      for (type, rep) in snap.representations {
        switch rep {
          case let .data(data):
            item.setData(data, forType: type)
          case let .string(string):
            item.setString(string, forType: type)
          case let .propertyList(plist):
            item.setPropertyList(plist, forType: type)
        }
      }
      return item
    }

    _ = pasteboard.writeObjects(items)
  }

  private func resetTypingAttributesForPaste() {
    // Note(@Mo) Important: In rich-text mode, AppKit can mutate `NSTextView.font` during paste based on the
    // inserted content (e.g. fixed-pitch code from an editor). If we only reset `typingAttributes`, AppKit
    // may later recompute them from the now-monospace `font` and we end up "stuck" typing in monospace.
    // Keep the view's base font stable and reset typing attributes on top.
    font = ComposeTextEditor.font
    textColor = NSColor.labelColor

    var attributes = defaultTypingAttributes
    if let paragraphStyle = typingAttributes[.paragraphStyle] {
      attributes[.paragraphStyle] = paragraphStyle
    }
    attributes[.underlineStyle] = 0
    typingAttributes = attributes
  }

  @discardableResult
  private func normalizeTabDelimitedListMarkers(in attributed: NSMutableAttributedString) -> Int {
    let fullRange = NSRange(location: 0, length: attributed.length)
    guard fullRange.length > 0 else { return 0 }
    var replacements = 0

    struct Pattern {
      let regex: NSRegularExpression
      let core: (NSTextCheckingResult, NSString) -> String?
    }

    func padded(_ core: String, to totalLength: Int) -> String {
      let coreLength = (core as NSString).length
      if coreLength == totalLength { return core }
      if coreLength > totalLength {
        return (core as NSString).substring(with: NSRange(location: 0, length: totalLength))
      }
      return core + String(repeating: " ", count: totalLength - coreLength)
    }

    func makePattern(_ pattern: String, core: @escaping (NSTextCheckingResult, NSString) -> String?) -> Pattern? {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
      return Pattern(regex: regex, core: core)
    }

    let patterns: [Pattern] = [
      // Numbered lists: "\t1\tItem" or "\t\t12\tItem"
      makePattern("^(\\t+)([0-9]+)\\t") { match, text in
        guard match.numberOfRanges >= 3 else { return nil }
        let digits = text.substring(with: match.range(at: 2))
        return "\(digits). "
      },
      // Lettered lists: "\tA\tItem"
      makePattern("^(\\t+)([A-Za-z])\\t") { match, text in
        guard match.numberOfRanges >= 3 else { return nil }
        let letter = text.substring(with: match.range(at: 2))
        return "\(letter). "
      },
      // Bulleted lists: "\t•\tItem"
      makePattern("^(\\t+)([\\u2022\\u25E6\\u00B7\\-])\\t") { match, text in
        guard match.numberOfRanges >= 3 else { return nil }
        let bullet = text.substring(with: match.range(at: 2))
        return "\(bullet) "
      },
    ].compactMap { $0 }

    let nsText = attributed.string as NSString
    for pattern in patterns {
      let matches = pattern.regex.matches(in: attributed.string, options: [], range: fullRange)
      for match in matches.reversed() {
        let totalLength = match.range(at: 0).length
        guard totalLength > 0 else { continue }
        guard let core = pattern.core(match, nsText) else { continue }
        attributed.replaceCharacters(in: match.range(at: 0), with: padded(core, to: totalLength))
        replacements += 1
      }
    }

    return replacements
  }
  #endif

  // MARK: - Drag & Drop Handling

  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
    var types = newTypes
    types.append(contentsOf: InlinePasteboard.draggedTypes)

    super.registerForDraggedTypes(types)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if LocalDragSurfaceGuard.isDragFromSameSurface(source: sender.draggingSource, destinationView: self) {
      return []
    }

    let pasteboard = sender.draggingPasteboard
    return canHandlePasteboard(pasteboard) ? .copy : super.draggingEntered(sender)
  }

  private func canHandlePasteboard(_ pasteboard: NSPasteboard) -> Bool {
    InlinePasteboard.canImportAttachments(
      from: pasteboard,
      includeText: false
    )
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if LocalDragSurfaceGuard.isDragFromSameSurface(source: sender.draggingSource, destinationView: self) {
      return false
    }

    // Prefer routing non-text content through our attachment pipeline.
    if handleAttachments(from: sender.draggingPasteboard, includeText: false) {
      return true
    }

    return super.performDragOperation(sender)
  }

  private func toggleTypingAttributesBold() {
    updateTypingAttributesIfNeeded()

    let snapshot = FormattingSnapshot(
      attributedString: NSAttributedString(attributedString: attributedString()),
      selectedRange: selectedRange(),
      typingAttributes: typingAttributes,
      actionName: boldUndoActionName
    )
    registerUndo(snapshot)

    let currentFont = (typingAttributes[.font] as? NSFont) ?? ComposeTextEditor.font
    let wantsBold = !PlatformFontTraits.isBold(currentFont)

    setTypingAttributesBold(wantsBold)
    notifyDelegateAboutFormattingChange()
  }

  private func toggleFontTrait(
    actionName: String,
    attribute: NSAttributedString.Key,
    contains: (NSFont) -> Bool,
    convert: (NSFont, Bool) -> NSFont
  ) {
    let range = selectedRange()
    guard range.location != NSNotFound else { return }

    let snapshot = FormattingSnapshot(
      attributedString: NSAttributedString(attributedString: attributedString()),
      selectedRange: range,
      typingAttributes: typingAttributes,
      actionName: actionName
    )
    registerUndo(snapshot)

    if range.length == 0 {
      var attributes = typingAttributes
      let font = (attributes[.font] as? NSFont) ?? ComposeTextEditor.font
      let enabled = !contains(font)
      attributes[.font] = convert(font, enabled)
      attributes[attribute] = enabled ? true : nil
      typingAttributes = attributes
    } else if let textStorage {
      let font = (textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        ?? ComposeTextEditor.font
      let enabled = !contains(font)
      var runs: [(NSRange, NSFont)] = []
      textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
        runs.append((subrange, (value as? NSFont) ?? ComposeTextEditor.font))
      }
      textStorage.beginEditing()
      for (subrange, runFont) in runs {
        textStorage.addAttribute(.font, value: convert(runFont, enabled), range: subrange)
        if enabled {
          textStorage.addAttribute(attribute, value: true, range: subrange)
        } else {
          textStorage.removeAttribute(attribute, range: subrange)
        }
      }
      textStorage.endEditing()
      setSelectedRange(range)
    }
    notifyDelegateAboutFormattingChange()
  }

  private func toggleBold(in range: NSRange) {
    guard let textStorage else { return }

    let fullRange = NSRange(location: 0, length: textStorage.length)
    let safeRange = NSIntersectionRange(range, fullRange)
    guard safeRange.length > 0 else { return }

    let snapshot = FormattingSnapshot(
      attributedString: NSAttributedString(attributedString: attributedString()),
      selectedRange: selectedRange(),
      typingAttributes: typingAttributes,
      actionName: boldUndoActionName
    )
    registerUndo(snapshot)

    let wantsBold = !isRangeFullyBold(safeRange)
    var fontRuns: [(range: NSRange, font: NSFont)] = []

    textStorage.enumerateAttribute(.font, in: safeRange, options: []) { value, subrange, _ in
      fontRuns.append((subrange, (value as? NSFont) ?? ComposeTextEditor.font))
    }

    textStorage.beginEditing()
    for fontRun in fontRuns {
      textStorage.addAttribute(
        .font,
        value: PlatformFontTraits.settingBold(wantsBold, on: fontRun.font),
        range: fontRun.range
      )
    }
    textStorage.endEditing()

    setTypingAttributesBold(wantsBold)
    setSelectedRange(safeRange)
    notifyDelegateAboutFormattingChange()
  }

  private func isRangeFullyBold(_ range: NSRange) -> Bool {
    guard range.length > 0 else { return false }

    var sawCharacters = false
    var allBold = true
    attributedString().enumerateAttribute(.font, in: range, options: []) { value, _, stop in
      sawCharacters = true
      let font = (value as? NSFont) ?? ComposeTextEditor.font
      if !PlatformFontTraits.isBold(font) {
        allBold = false
        stop.pointee = true
      }
    }

    return sawCharacters && allBold
  }

  private func registerUndo(_ snapshot: FormattingSnapshot) {
    undoManager?.registerUndo(withTarget: self) { target in
      target.restoreFormattingSnapshot(snapshot)
    }
    undoManager?.setActionName(snapshot.actionName)
  }

  private func restoreFormattingSnapshot(_ snapshot: FormattingSnapshot) {
    registerUndo(
      FormattingSnapshot(
        attributedString: NSAttributedString(attributedString: attributedString()),
        selectedRange: selectedRange(),
        typingAttributes: typingAttributes,
        actionName: snapshot.actionName
      )
    )

    textStorage?.setAttributedString(snapshot.attributedString)
    setSelectedRange(snapshot.selectedRange)
    typingAttributes = snapshot.typingAttributes
    notifyDelegateAboutFormattingChange()
  }

  private func setTypingAttributesBold(_ wantsBold: Bool) {
    var newTypingAttributes = typingAttributes
    let currentFont = (newTypingAttributes[.font] as? NSFont) ?? ComposeTextEditor.font
    newTypingAttributes[.font] = PlatformFontTraits.settingBold(wantsBold, on: currentFont)
    newTypingAttributes[.underlineStyle] = newTypingAttributes[.richTextUnderline] as? Bool == true
      ? NSUnderlineStyle.single.rawValue : 0
    typingAttributes = newTypingAttributes
  }
}

private struct FormattingSnapshot {
  let attributedString: NSAttributedString
  let selectedRange: NSRange
  let typingAttributes: [NSAttributedString.Key: Any]
  let actionName: String
}

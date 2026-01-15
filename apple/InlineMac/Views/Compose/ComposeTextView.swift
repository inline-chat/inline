import AppKit
import InlineKit

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
  func textView(_ textView: NSTextView, didFailToPasteAttachment failure: PasteboardAttachmentFailure)
  // Mention handling
  func textView(_ textView: NSTextView, didDetectMentionWith query: String, at location: Int)
  func textViewDidCancelMention(_ textView: NSTextView)
  // Focus handling
  func textViewDidGainFocus(_ textView: NSTextView)
  func textViewDidLoseFocus(_ textView: NSTextView)
}

class ComposeNSTextView: NSTextView {
  private var isStrippingEmailLinks = false

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

  override func didChangeText() {
    super.didChangeText()
    stripEmailLinkAttributes()
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

    if attachments.isEmpty, let failure = preferredFailure(from: result.failures) {
      (delegate as? ComposeTextViewDelegate)?.textView(self, didFailToPasteAttachment: failure)
    }

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

  override func paste(_ sender: Any?) {
    // Intercept non-text content (files/images/videos) and route through our attachment pipeline.
    if handleAttachments(from: .general, includeText: false) {
      return
    }

    // Note(@Mo) Important: Temporarily disable rich-text paste entirely. We still rely on AppKit's native
    // plain-text paste pipeline for correct undo/redo, IME behavior, and selection handling, but we do not
    // allow any clipboard-provided styling to enter the compose view while we stabilize edge cases.
    resetTypingAttributesToDefault()
    super.pasteAsPlainText(sender)
    resetTypingAttributesToDefault()
    DispatchQueue.main.async { [weak self] in
      self?.resetTypingAttributesToDefault()
    }
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

    // Strip underline everywhere; we don't support it (and links shouldn't be underlined either).
    if fullRange.length > 0 {
      sanitized.addAttribute(.underlineStyle, value: 0, range: fullRange)
      sanitized.removeAttribute(.underlineColor, range: fullRange)
    }

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
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased()
    else { return false }
    return Self.allowedExternalLinkSchemes.contains(scheme)
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

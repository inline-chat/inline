import AppKit
import Carbon.HIToolbox


/// This module handles RTL/LTR detection for paragraphs in macOS compose
/// Behaviour should match iMessage/Apple Notes app. Also caret positioning is handled based
/// on input source when user hasn't started typing yet.
@MainActor
final class ComposeParagraphDirectionController {
  private weak var textView: NSTextView?
  private var observer: NSObjectProtocol?
  private var isUpdating = false
  private let emptyParagraphChars = CharacterSet.whitespacesAndNewlines

  init(textView: NSTextView) {
    self.textView = textView
    observer = NotificationCenter.default.addObserver(
      forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.applyInputSourceDirectionIfNeeded()
      }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func textDidChange() {
    guard let textView else { return }
    refreshChangedParagraphDirections(in: textView)
    applyInputSourceDirectionIfNeeded()
  }

  func selectionDidChange() {
    applyInputSourceDirectionIfNeeded()
  }

  func didGainFocus() {
    applyInputSourceDirectionIfNeeded()
  }

  func refreshAllParagraphDirections() {
    guard let textView else { return }
    refreshParagraphDirections(in: textView, within: fullDocumentRange(in: textView))
    applyInputSourceDirectionIfNeeded()
  }

  private func refreshChangedParagraphDirections(in textView: NSTextView) {
    guard let range = changedParagraphRange(in: textView) else { return }
    refreshParagraphDirections(in: textView, within: range)
  }

  private func refreshParagraphDirections(in textView: NSTextView, within scope: NSRange?) {
    guard !isUpdating else { return }
    guard let scope else { return }

    isUpdating = true
    defer { isUpdating = false }

    let text = textView.string as NSString
    let end = NSMaxRange(scope)
    var location = scope.location

    while location < end {
      let range = text.paragraphRange(for: NSRange(location: location, length: 0))
      let paragraphText = text.substring(with: range)
      if let direction = inferredWritingDirection(for: paragraphText) {
        apply(direction: direction, to: range, in: textView)
      }
      location = NSMaxRange(range)
    }
  }

  private func applyInputSourceDirectionIfNeeded() {
    guard !isUpdating, let textView else { return }
    guard textView.window?.firstResponder as? NSTextView === textView else { return }

    let selection = textView.selectedRange()
    guard selection.length == 0 else { return }

    let paragraph = currentParagraph(in: textView, selection: selection)
    guard paragraph.text.unicodeScalars.allSatisfy(emptyParagraphChars.contains) else { return }
    guard let direction = currentInputSourceDirection() else { return }

    isUpdating = true
    defer { isUpdating = false }
    apply(direction: direction, to: paragraph.range, in: textView)
  }

  private func apply(direction: NSWritingDirection, to range: NSRange, in textView: NSTextView) {
    let alignment = paragraphAlignment(for: direction)
    let currentStyle = currentParagraphStyle(in: textView, at: range)
    if currentStyle?.baseWritingDirection != direction {
      textView.setBaseWritingDirection(direction, range: range)
    }
    if currentStyle?.alignment != alignment {
      textView.setAlignment(alignment, range: range)
    }

    var typingAttributes = textView.typingAttributes
    let updatedStyle = paragraphStyle(
      from: typingAttributes[.paragraphStyle] as? NSParagraphStyle,
      direction: direction,
      alignment: alignment
    )
    if let existingStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle,
       existingStyle.baseWritingDirection == updatedStyle.baseWritingDirection,
       existingStyle.alignment == updatedStyle.alignment
    {
      return
    }

    typingAttributes[.paragraphStyle] = updatedStyle
    textView.typingAttributes = typingAttributes
  }

  private func currentParagraph(in textView: NSTextView, selection: NSRange) -> (range: NSRange, text: String) {
    let text = textView.string as NSString
    guard text.length > 0 else { return (NSRange(location: selection.location, length: 0), "") }

    if selection.location >= text.length {
      if textView.string.hasSuffix("\n") {
        return (NSRange(location: text.length, length: 0), "")
      }

      let range = text.paragraphRange(for: NSRange(location: text.length - 1, length: 0))
      return (range, text.substring(with: range))
    }

    let range = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
    return (range, text.substring(with: range))
  }

  private func currentInputSourceDirection() -> NSWritingDirection? {
    guard let sourceRef = TISCopyCurrentKeyboardInputSource() else { return .natural }
    let source = sourceRef.takeRetainedValue()

    if let langsPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
      let langs = Unmanaged<CFArray>.fromOpaque(langsPtr).takeUnretainedValue() as? [String]
      if langs?.contains(where: isRTLLanguageTag) == true {
        return .rightToLeft
      }
      if langs?.isEmpty == false {
        return .natural
      }
    }

    if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
      let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
      if isRTLInputSourceID(id) {
        return .rightToLeft
      }
      return .natural
    }

    return .natural
  }

  private func fullDocumentRange(in textView: NSTextView) -> NSRange? {
    let text = textView.string as NSString
    guard text.length > 0 else { return nil }
    return NSRange(location: 0, length: text.length)
  }

  private func changedParagraphRange(in textView: NSTextView) -> NSRange? {
    let text = textView.string as NSString
    guard text.length > 0 else { return nil }

    if let editedRange = textView.textStorage?.editedRange, editedRange.location != NSNotFound {
      return paragraphRangeCoveringEdit(editedRange, in: text)
    }

    return currentParagraph(in: textView, selection: textView.selectedRange()).range
  }

  private func paragraphRangeCoveringEdit(_ editedRange: NSRange, in text: NSString) -> NSRange {
    let start = min(max(editedRange.location, 0), text.length)
    let safeLength = min(max(editedRange.length, 0), text.length - start)
    let end = min(start + safeLength, text.length)

    let startRange: NSRange
    if start >= text.length {
      startRange = text.paragraphRange(for: NSRange(location: max(text.length - 1, 0), length: 0))
    } else {
      startRange = text.paragraphRange(for: NSRange(location: start, length: 0))
    }

    let endRange: NSRange
    if end == 0 {
      endRange = startRange
    } else {
      let endLocation = min(end - 1, text.length - 1)
      endRange = text.paragraphRange(for: NSRange(location: endLocation, length: 0))
    }

    return NSUnionRange(startRange, endRange)
  }

  private func currentParagraphStyle(in textView: NSTextView, at range: NSRange) -> NSParagraphStyle? {
    guard let textStorage = textView.textStorage, textStorage.length > 0 else { return nil }
    let location = min(range.location, max(textStorage.length - 1, 0))
    return textStorage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
  }

  private func isRTLLanguageTag(_ tag: String) -> Bool {
    let normalized = tag.lowercased().replacingOccurrences(of: "-", with: "_")
    let parts = normalized.split(separator: "_")
    guard let first = parts.first else { return false }
    if rtlLanguageCodes.contains(String(first)) {
      return true
    }
    return parts.contains(where: { rtlScriptCodes.contains(String($0)) })
  }

  private func isRTLInputSourceID(_ id: String) -> Bool {
    let normalized = id.lowercased()
    return rtlInputSourceHints.contains(where: { normalized.contains($0) })
  }

  private func inferredWritingDirection(for text: String) -> NSWritingDirection? {
    for scalar in text.unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.punctuationCharacters.contains(scalar)
        || CharacterSet.symbols.contains(scalar)
        || CharacterSet.decimalDigits.contains(scalar)
      {
        continue
      }

      if isRTLScalar(scalar) {
        return .rightToLeft
      }

      if scalar.properties.isAlphabetic {
        return .leftToRight
      }
    }

    return nil
  }

  private func isRTLScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
      case 0x0590 ... 0x08FF,
           0xFB1D ... 0xFDFF,
           0xFE70 ... 0xFEFF,
           0x10800 ... 0x10FFF:
        return true
      default:
        return false
    }
  }

  private func paragraphAlignment(for direction: NSWritingDirection) -> NSTextAlignment {
    switch direction {
      case .rightToLeft:
        return .right
      case .leftToRight:
        return .left
      case .natural:
        return .natural
      @unknown default:
        return .natural
    }
  }

  private func paragraphStyle(
    from existing: NSParagraphStyle?,
    direction: NSWritingDirection,
    alignment: NSTextAlignment
  ) -> NSParagraphStyle {
    let style = (existing?.mutableCopy() as? NSMutableParagraphStyle)
      ?? (NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle)
    style.baseWritingDirection = direction
    style.alignment = alignment
    return style.copy() as! NSParagraphStyle
  }

  private let rtlLanguageCodes: Set<String> = [
    "ar", "fa", "he", "ur", "ps", "sd", "ug", "yi", "dv", "ku", "ckb",
  ]

  private let rtlScriptCodes: Set<String> = [
    "arab", "hebr", "syrc", "thaa", "nkoo", "adlm", "rohg",
  ]

  private let rtlInputSourceHints: [String] = [
    "arabic", "persian", "hebrew", "urdu", "pashto", "sorani", "uighur", "uyghur", "yiddish",
  ]
}

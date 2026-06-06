import AppKit
import InlineKit
import Logger
import TextProcessing

enum MessageGestureTrace {
  static let prefix = "[MessageGestureTrace]"
  private static let log = Log.scoped("MessageGesture", enableTracing: true)

  static func trace(_ message: @autoclosure () -> String) {
    log.trace("\(prefix) \(message())")
  }

  static func debug(_ message: @autoclosure () -> String) {
    log.debug("\(prefix) \(message())")
  }

  static func point(_ point: NSPoint) -> String {
    "(\(String(format: "%.1f", point.x)),\(String(format: "%.1f", point.y)))"
  }

  static func range(_ range: NSRange?) -> String {
    guard let range else { return "nil" }
    return "{loc:\(range.location),len:\(range.length)}"
  }

  static func url(_ url: URL?) -> String {
    guard let url else { return "nil" }
    let scheme = url.scheme ?? "nil"
    let host = url.host ?? "nil"
    return "{scheme:\(scheme),host:\(host),pathLen:\(url.path.count),query:\(url.query != nil),fragment:\(url.fragment != nil)}"
  }
}

enum MessageTextEntityHit: CustomStringConvertible {
  case codeBlock(NSRange)
  case inlineCode(NSRange)
  case text(NSRange)

  var description: String {
    switch self {
    case let .codeBlock(range):
      return "codeBlock \(MessageGestureTrace.range(range))"
    case let .inlineCode(range):
      return "inlineCode \(MessageGestureTrace.range(range))"
    case let .text(range):
      return "text \(MessageGestureTrace.range(range))"
    }
  }
}

// Custom NSTextView subclass to handle hit testing
class MessageTextView: NSTextView {
  var codeBlockStyle = CodeBlockStyle.block
  var inlineCodeStyle = CodeBlockStyle.inline

  // NSTextView can consume click recognizers before their target actions run.
  // The owning message view handles links/entities here and returns true only
  // when the click should not continue into AppKit text selection.
  var onEntityClick: ((NSPoint, NSEvent) -> Bool)?

  override func resignFirstResponder() -> Bool {
    // Clear out selection when user clicks somewhere else
    selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]

    return super.resignFirstResponder()
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    false
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Prevent hit testing when window is inactive
    guard let window, window.isKeyWindow else {
      MessageGestureTrace.trace("MessageTextView.hitTest blocked inactiveWindow point=\(MessageGestureTrace.point(point))")
      return nil
    }
    let hit = super.hitTest(point)
    MessageGestureTrace.trace(
      "MessageTextView.hitTest point=\(MessageGestureTrace.point(point)) hit=\(String(describing: hit.map { type(of: $0) }))"
    )
    return hit
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    disableSystemTextChecking()
  }

  override func mouseDown(with event: NSEvent) {
    disableSystemTextChecking()
    let location = convert(event.locationInWindow, from: nil)
    MessageGestureTrace.debug(
      "MessageTextView.mouseDown clickCount=\(event.clickCount) point=\(MessageGestureTrace.point(location)) type=\(event.type.rawValue)"
    )

    // Ensure window is key before handling mouse events
    guard let window else {
      MessageGestureTrace.debug("MessageTextView.mouseDown noWindow forwardingToSuper")
      super.mouseDown(with: event)
      return
    }

    if !window.isKeyWindow {
      MessageGestureTrace.debug("MessageTextView.mouseDown inactiveWindow makeKeyAndReturn")
      window.makeKeyAndOrderFront(nil)
      // Optionally, you can choose to not forward the event
      return
    }

    if event.type == .leftMouseDown, event.clickCount == 1 {
      let handled = onEntityClick?(location, event) ?? false
      MessageGestureTrace.debug(
        "MessageTextView.mouseDown entityClickAttempt point=\(MessageGestureTrace.point(location)) handled=\(handled)"
      )
      if handled { return }
    }

    MessageGestureTrace.trace("MessageTextView.mouseDown forwardingToSuper")
    super.mouseDown(with: event)
  }

  private func disableSystemTextChecking() {
    // Message text is rendered read-only content. AppKit can still run text checking,
    // inline prediction, or Writing Tools while tracking selection, which has shown
    // up in hangs inside NSTextCheckingController. Inline handles links/entities itself.
    isContinuousSpellCheckingEnabled = false
    isGrammarCheckingEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isAutomaticDataDetectionEnabled = false
    isAutomaticTextCompletionEnabled = false
    smartInsertDeleteEnabled = false
    enabledTextCheckingTypes = 0

    if #available(macOS 14.0, *) {
      inlinePredictionType = .no
    }

    if #available(macOS 15.0, *) {
      writingToolsBehavior = .none
      mathExpressionCompletionType = .no
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    drawCodeBlocks(in: dirtyRect)
    drawInlineCode(in: dirtyRect)
    super.draw(dirtyRect)
  }

  func codeBlockRange(at point: NSPoint) -> NSRange? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    var match: NSRange?
    textStorage.enumerateAttribute(.codeBlock, in: fullRange, options: []) { value, range, stop in
      guard (value as? Bool) == true else { return }
      guard let blockRect = codeBlockRect(for: range, style: codeBlockStyle),
            blockRect.contains(point)
      else { return }
      match = range
      stop.pointee = true
    }
    return match
  }

  func inlineCodeRange(at point: NSPoint) -> NSRange? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    var match: NSRange?
    textStorage.enumerateAttribute(.inlineCode, in: fullRange, options: []) { value, range, stop in
      guard (value as? Bool) == true else { return }
      guard inlineCodeRects(for: range, style: inlineCodeStyle).contains(where: { $0.contains(point) }) else {
        return
      }
      match = range
      stop.pointee = true
    }
    return match
  }

  func entityHit(at point: NSPoint, extraTextRanges: [NSRange]) -> MessageTextEntityHit? {
    if let codeRange = codeBlockRange(at: point) {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) result=codeBlock range=\(MessageGestureTrace.range(codeRange))"
      )
      return .codeBlock(codeRange)
    }

    if let inlineCodeRange = inlineCodeRange(at: point) {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) result=inlineCode range=\(MessageGestureTrace.range(inlineCodeRange))"
      )
      return .inlineCode(inlineCodeRange)
    }

    guard let textStorage, textStorage.length > 0 else {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) result=nil reason=noTextStorage"
      )
      return nil
    }

    guard let characterIndex = characterIndex(at: point), characterIndex < textStorage.length else {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) result=nil reason=noCharacterIndex"
      )
      return nil
    }

    let ranges = entityRanges(in: textStorage, extraRanges: extraTextRanges)
    guard let range = ranges.first(where: { NSLocationInRange(characterIndex, $0) }) else {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) char=\(characterIndex) result=nil reason=noEntity"
      )
      return nil
    }

    guard renderedRange(range, contains: point) else {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) char=\(characterIndex) result=nil reason=outsideRenderedEntity range=\(MessageGestureTrace.range(range))"
      )
      return nil
    }

    MessageGestureTrace.debug(
      "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) char=\(characterIndex) result=text range=\(MessageGestureTrace.range(range))"
    )
    return .text(range)
  }

  func renderedTextContains(_ point: NSPoint) -> Bool {
    let range = renderedCharacterRange(at: point)
    let contains = range != nil
    MessageGestureTrace.trace(
      "MessageTextView.renderedTextContains point=\(MessageGestureTrace.point(point)) contains=\(contains) range=\(MessageGestureTrace.range(range))"
    )
    return contains
  }

  private func entityRanges(in textStorage: NSTextStorage, extraRanges: [NSRange]) -> [NSRange] {
    let fullRange = NSRange(location: 0, length: textStorage.length)
    let keys: [NSAttributedString.Key] = [
      .mentionUserId,
      .threadLink,
      .emailAddress,
      .phoneNumber,
      .link,
    ]

    var ranges = extraRanges
    for key in keys {
      textStorage.enumerateAttribute(key, in: fullRange, options: []) { value, range, _ in
        guard value != nil else { return }
        ranges.append(range)
      }
    }

    return normalizedRanges(ranges, maxLength: textStorage.length)
  }

  private func characterIndex(at point: NSPoint) -> Int? {
    guard let textStorage, textStorage.length > 0 else { return nil }

    if let layoutManager, let textContainer {
      let containerPoint = NSPoint(
        x: point.x - textContainerInset.width,
        y: point.y - textContainerInset.height
      )
      let characterIndex = layoutManager.characterIndex(
        for: containerPoint,
        in: textContainer,
        fractionOfDistanceBetweenInsertionPoints: nil
      )
      guard characterIndex != NSNotFound, characterIndex < textStorage.length else { return nil }
      return characterIndex
    }

    let characterIndex = characterIndexForInsertion(at: point)
    guard characterIndex != NSNotFound, characterIndex < textStorage.length else { return nil }
    return characterIndex
  }

  private func renderedCharacterRange(at point: NSPoint) -> NSRange? {
    guard let textStorage, textStorage.length > 0 else { return nil }

    if let layoutManager, let textContainer {
      let containerPoint = NSPoint(
        x: point.x - textContainerInset.width,
        y: point.y - textContainerInset.height
      )
      var fraction: CGFloat = 0
      let glyphIndex = layoutManager.glyphIndex(
        for: containerPoint,
        in: textContainer,
        fractionOfDistanceThroughGlyph: &fraction
      )
      guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }

      var glyphRect = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyphIndex, length: 1),
        in: textContainer
      )
      glyphRect.origin.x += textContainerInset.width
      glyphRect.origin.y += textContainerInset.height
      guard glyphRect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }

      let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
      guard characterIndex != NSNotFound, characterIndex < textStorage.length else { return nil }
      return NSRange(location: characterIndex, length: 1)
    }

    guard let characterIndex = characterIndex(at: point) else { return nil }
    let characterRange = NSRange(location: characterIndex, length: 1)
    return renderedStandardRange(characterRange, contains: point) ? characterRange : nil
  }

  private func renderedRange(_ range: NSRange, contains point: NSPoint) -> Bool {
    if let textLayoutManager, let textContentManager = textLayoutManager.textContentManager {
      guard let textRange = textRange(for: range, in: textContentManager) else { return false }
      var contains = false
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .selection,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        var adjusted = segmentRect
        adjusted.origin.x += self.textContainerInset.width
        adjusted.origin.y += self.textContainerInset.height
        if adjusted.insetBy(dx: -1, dy: -1).contains(point) {
          contains = true
          return false
        }
        return true
      }
      return contains
    }

    guard let layoutManager, let textContainer else { return false }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return false }

    var contains = false
    layoutManager.enumerateEnclosingRects(
      forGlyphRange: glyphRange,
      withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
      in: textContainer
    ) { rect, stop in
      var adjusted = rect
      adjusted.origin.x += self.textContainerInset.width
      adjusted.origin.y += self.textContainerInset.height
      if adjusted.insetBy(dx: -1, dy: -1).contains(point) {
        contains = true
        stop.pointee = true
      }
    }
    return contains
  }

  private func renderedStandardRange(_ range: NSRange, contains point: NSPoint) -> Bool {
    if let textLayoutManager, let textContentManager = textLayoutManager.textContentManager {
      guard let textRange = textRange(for: range, in: textContentManager) else { return false }
      var contains = false
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .standard,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        var adjusted = segmentRect
        adjusted.origin.x += self.textContainerInset.width
        adjusted.origin.y += self.textContainerInset.height
        if adjusted.insetBy(dx: -2, dy: -2).contains(point) {
          contains = true
          return false
        }
        return true
      }
      return contains
    }

    return renderedRange(range, contains: point)
  }

  private func textRange(for range: NSRange, in textContentManager: NSTextContentManager) -> NSTextRange? {
    let documentRange = textContentManager.documentRange
    guard let startLocation = textContentManager.location(documentRange.location, offsetBy: range.location),
          let endLocation = textContentManager.location(startLocation, offsetBy: range.length)
    else { return nil }
    return NSTextRange(location: startLocation, end: endLocation)
  }

  private func normalizedRanges(_ ranges: [NSRange], maxLength: Int) -> [NSRange] {
    var result: [NSRange] = []

    for range in ranges {
      guard range.location != NSNotFound,
            range.location < maxLength,
            range.length > 0
      else { continue }

      let end = min(maxLength, range.location + range.length)
      guard end > range.location else { continue }

      let safeRange = NSRange(location: range.location, length: end - range.location)
      guard !result.contains(where: { NSEqualRanges($0, safeRange) }) else { continue }
      result.append(safeRange)
    }

    return result
  }

  private func drawCodeBlocks(in rect: NSRect) {
    guard let textStorage, textStorage.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.codeBlock, in: fullRange, options: []) { value, range, _ in
      guard (value as? Bool) == true else { return }
      guard let blockRect = codeBlockRect(for: range, style: codeBlockStyle),
            blockRect.intersects(rect)
      else { return }
      let backgroundColor = (textStorage.attribute(.codeBlockBackground, at: range.location, effectiveRange: nil)
        as? NSColor) ?? NSColor.labelColor.withAlphaComponent(0.08)
      let path = NSBezierPath(roundedRect: blockRect, xRadius: codeBlockStyle.cornerRadius, yRadius: codeBlockStyle.cornerRadius)
      backgroundColor.setFill()
      path.fill()
    }
  }

  private func drawInlineCode(in rect: NSRect) {
    guard let textStorage, textStorage.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.inlineCode, in: fullRange, options: []) { value, range, _ in
      guard (value as? Bool) == true else { return }
      let backgroundColor = (textStorage.attribute(.inlineCodeBackground, at: range.location, effectiveRange: nil)
        as? NSColor) ?? NSColor.labelColor.withAlphaComponent(0.12)
      for inlineRect in inlineCodeRects(for: range, style: inlineCodeStyle) where inlineRect.intersects(rect) {
        let path = NSBezierPath(
          roundedRect: inlineRect,
          xRadius: inlineCodeStyle.cornerRadius,
          yRadius: inlineCodeStyle.cornerRadius
        )
        backgroundColor.setFill()
        path.fill()
      }
    }
  }

  private func codeBlockRect(for range: NSRange, style: CodeBlockStyle) -> NSRect? {
    if let textLayoutManager = textLayoutManager,
       let textContentManager = textLayoutManager.textContentManager
    {
      let documentRange = textContentManager.documentRange
      guard let startLocation = textContentManager.location(documentRange.location, offsetBy: range.location),
            let endLocation = textContentManager.location(startLocation, offsetBy: range.length)
      else { return nil }
      guard let textRange = NSTextRange(location: startLocation, end: endLocation) else { return nil }
      var unionRect: NSRect?
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .standard,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        var adjusted = segmentRect
        adjusted.origin.x += textContainerInset.width
        adjusted.origin.y += textContainerInset.height
        unionRect = unionRect?.union(adjusted) ?? adjusted
        return true
      }
      if var rect = unionRect {
        rect.origin.x -= style.textInsetLeft
        rect.size.width += style.textInsetLeft + style.textInsetRight
        rect.origin.y -= style.verticalPadding
        rect.size.height += style.verticalPadding * 2
        let insetBounds = bounds.insetBy(dx: style.blockHorizontalInset, dy: 0)
        let clipped = rect.intersection(insetBounds)
        return clipped.isNull ? nil : clipped
      }
      return nil
    }

    guard let layoutManager, let textContainer else { return nil }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return nil }

    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    rect.origin.x += textContainerInset.width
    rect.origin.y += textContainerInset.height

    var padded = rect
    padded.origin.x -= style.textInsetLeft
    padded.size.width += style.textInsetLeft + style.textInsetRight
    padded.origin.y -= style.verticalPadding
    padded.size.height += style.verticalPadding * 2

    let insetBounds = bounds.insetBy(dx: style.blockHorizontalInset, dy: 0)
    let clipped = padded.intersection(insetBounds)
    return clipped.isNull ? nil : clipped
  }

  private func inlineCodeRects(for range: NSRange, style: CodeBlockStyle) -> [NSRect] {
    if let textLayoutManager = textLayoutManager,
       let textContentManager = textLayoutManager.textContentManager
    {
      let documentRange = textContentManager.documentRange
      guard let startLocation = textContentManager.location(documentRange.location, offsetBy: range.location),
            let endLocation = textContentManager.location(startLocation, offsetBy: range.length),
            let textRange = NSTextRange(location: startLocation, end: endLocation)
      else { return [] }

      var rects: [NSRect] = []
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .selection,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        if let adjustedRect = self.adjustedInlineCodeRect(for: segmentRect, style: style) {
          rects.append(adjustedRect)
        }
        return true
      }
      return mergeInlineCodeRects(rects)
    }

    guard let layoutManager, let textContainer else { return [] }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return [] }

    var rects: [NSRect] = []
    layoutManager.enumerateEnclosingRects(
      forGlyphRange: glyphRange,
      withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
      in: textContainer
    ) { rect, _ in
      var adjusted = rect
      adjusted.origin.x += self.textContainerInset.width
      adjusted.origin.y += self.textContainerInset.height
      if let adjustedRect = self.adjustedInlineCodeRect(for: adjusted, style: style) {
        rects.append(adjustedRect)
      }
    }

    return mergeInlineCodeRects(rects)
  }

  private func adjustedInlineCodeRect(for rect: NSRect, style: CodeBlockStyle) -> NSRect? {
    guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }

    var padded = rect
    padded.origin.x -= style.textInsetLeft
    padded.size.width += style.textInsetLeft + style.textInsetRight
    padded.origin.y -= style.verticalPadding
    padded.size.height += style.verticalPadding * 2

    let insetBounds = bounds.insetBy(dx: style.blockHorizontalInset, dy: 0)
    let clipped = padded.intersection(insetBounds)
    return clipped.isNull ? nil : clipped
  }

  private func mergeInlineCodeRects(_ rects: [NSRect]) -> [NSRect] {
    let tolerance: CGFloat = 1
    let sortedRects = rects.sorted { lhs, rhs in
      if abs(lhs.minY - rhs.minY) > tolerance {
        return lhs.minY < rhs.minY
      }
      return lhs.minX < rhs.minX
    }

    var mergedRects: [NSRect] = []
    for rect in sortedRects {
      guard var lastRect = mergedRects.last else {
        mergedRects.append(rect)
        continue
      }

      let sameLine = abs(lastRect.minY - rect.minY) <= tolerance
        && abs(lastRect.height - rect.height) <= tolerance
      let overlapsOrTouches = rect.minX <= lastRect.maxX + tolerance

      if sameLine && overlapsOrTouches {
        lastRect = lastRect.union(rect)
        mergedRects[mergedRects.count - 1] = lastRect
      } else {
        mergedRects.append(rect)
      }
    }

    return mergedRects
  }
}

extension NSTextView {
  func setMessageAttributedString(
    _ attributedString: NSAttributedString,
    isRtl: Bool,
    layoutSize: CGSize,
    useTextKit2: Bool
  ) {
    let direction: NSWritingDirection = isRtl ? .rightToLeft : .leftToRight
    let alignment: NSTextAlignment = isRtl ? .right : .left
    let displayedString = attributedString.messageApplyingParagraphDirection(
      direction: direction,
      alignment: alignment
    )

    textStorage?.setAttributedString(displayedString)
    self.alignment = alignment

    let fullRange = NSRange(location: 0, length: displayedString.length)
    if fullRange.length > 0 {
      setAlignment(alignment, range: fullRange)
      setBaseWritingDirection(direction, range: fullRange)
    }

    textContainer?.size = layoutSize
    if !useTextKit2, let textContainer {
      layoutManager?.ensureLayout(for: textContainer)
    }
  }
}

private extension NSAttributedString {
  func messageApplyingParagraphDirection(
    direction: NSWritingDirection,
    alignment: NSTextAlignment
  ) -> NSAttributedString {
    guard length > 0 else { return self }

    let result = NSMutableAttributedString(attributedString: self)
    let fullRange = NSRange(location: 0, length: length)
    result.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
      let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
        ?? (NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle)
      style.baseWritingDirection = direction
      style.alignment = alignment
      result.addAttribute(.paragraphStyle, value: style, range: range)
    }
    return result
  }
}

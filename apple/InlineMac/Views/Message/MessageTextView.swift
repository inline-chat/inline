import AppKit
import InlineKit
import TextProcessing

// Custom NSTextView subclass to handle hit testing
class MessageTextView: NSTextView {
  var codeBlockStyle = CodeBlockStyle.block
  var inlineCodeStyle = CodeBlockStyle.inline

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
      return nil
    }
    return super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    // Ensure window is key before handling mouse events
    guard let window else {
      super.mouseDown(with: event)
      return
    }

    if !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
      // Optionally, you can choose to not forward the event
      return
    }

    super.mouseDown(with: event)
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

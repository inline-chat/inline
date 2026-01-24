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

      let textColor = (textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
        as? NSColor) ?? NSColor.labelColor
      let lineColor = textColor.withAlphaComponent(0.35)
      let lineRect = NSRect(
        x: blockRect.minX,
        y: blockRect.minY,
        width: codeBlockStyle.lineWidth,
        height: blockRect.height
      )
      let linePath = NSBezierPath(roundedRect: lineRect, xRadius: codeBlockStyle.lineWidth / 2, yRadius: codeBlockStyle.lineWidth / 2)
      if let context = NSGraphicsContext.current?.cgContext {
        context.saveGState()
        context.addPath(path.cgPath)
        context.clip()
        lineColor.setFill()
        linePath.fill()
        context.restoreGState()
      } else {
        lineColor.setFill()
        linePath.fill()
      }
    }
  }

  private func drawInlineCode(in rect: NSRect) {
    guard let textStorage, textStorage.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.inlineCode, in: fullRange, options: []) { value, range, _ in
      guard (value as? Bool) == true else { return }
      guard let inlineRect = codeBlockRect(for: range, style: inlineCodeStyle),
            inlineRect.intersects(rect)
      else { return }
      let backgroundColor = (textStorage.attribute(.inlineCodeBackground, at: range.location, effectiveRange: nil)
        as? NSColor) ?? NSColor.labelColor.withAlphaComponent(0.12)
      let path = NSBezierPath(roundedRect: inlineRect, xRadius: inlineCodeStyle.cornerRadius, yRadius: inlineCodeStyle.cornerRadius)
      backgroundColor.setFill()
      path.fill()

      let textColor = (textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
        as? NSColor) ?? NSColor.labelColor
      let lineColor = textColor.withAlphaComponent(0.35)
      let lineRect = NSRect(
        x: inlineRect.minX,
        y: inlineRect.minY,
        width: inlineCodeStyle.lineWidth,
        height: inlineRect.height
      )
      let linePath = NSBezierPath(roundedRect: lineRect, xRadius: inlineCodeStyle.lineWidth / 2, yRadius: inlineCodeStyle.lineWidth / 2)
      if let context = NSGraphicsContext.current?.cgContext {
        context.saveGState()
        context.addPath(path.cgPath)
        context.clip()
        lineColor.setFill()
        linePath.fill()
        context.restoreGState()
      } else {
        lineColor.setFill()
        linePath.fill()
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

    rect.origin.x -= style.textInsetLeft
    rect.size.width += style.textInsetLeft + style.textInsetRight
    rect.origin.y -= style.verticalPadding
    rect.size.height += style.verticalPadding * 2

    let insetBounds = bounds.insetBy(dx: style.blockHorizontalInset, dy: 0)
    let clipped = rect.intersection(insetBounds)
    return clipped.isNull ? nil : clipped
  }
}

import InlineKit
import TextProcessing
import UIKit

final class CodeBlockTextView: UITextView {
  var codeBlockStyle = CodeBlockStyle.block
  var inlineCodeStyle = CodeBlockStyle.inline

  override func draw(_ rect: CGRect) {
    drawCodeBlocks(in: rect)
    drawInlineCode(in: rect)
    super.draw(rect)
  }

  func codeBlockRange(at point: CGPoint) -> NSRange? {
    let textStorage = self.textStorage
    guard textStorage.length > 0 else { return nil }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    var match: NSRange?
    textStorage.enumerateAttribute(.codeBlock, in: fullRange, options: []) { value, range, stop in
      guard (value as? Bool) == true else { return }
      guard let blockRect = codeBlockRect(for: range, style: codeBlockStyle, tight: false),
            blockRect.contains(point)
      else { return }
      match = range
      stop.pointee = true
    }
    return match
  }

  private func drawCodeBlocks(in rect: CGRect) {
    let textStorage = self.textStorage
    guard textStorage.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.codeBlock, in: fullRange, options: []) { value, range, _ in
      guard (value as? Bool) == true else { return }
      guard let blockRect = codeBlockRect(for: range, style: codeBlockStyle, tight: false),
            blockRect.intersects(rect)
      else { return }
      let backgroundColor = (textStorage.attribute(.codeBlockBackground, at: range.location, effectiveRange: nil)
        as? UIColor) ?? UIColor.label.withAlphaComponent(0.08)
      let path = UIBezierPath(roundedRect: blockRect, cornerRadius: codeBlockStyle.cornerRadius)
      backgroundColor.setFill()
      path.fill()

      let textColor = (textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
        as? UIColor) ?? tintColor ?? UIColor.label
      let lineColor = textColor.withAlphaComponent(0.35)
      let lineRect = CGRect(
        x: blockRect.minX,
        y: blockRect.minY,
        width: codeBlockStyle.lineWidth,
        height: blockRect.height
      )
      let linePath = UIBezierPath(roundedRect: lineRect, cornerRadius: codeBlockStyle.lineWidth / 2)
      if let context = UIGraphicsGetCurrentContext() {
        context.saveGState()
        path.addClip()
        lineColor.setFill()
        linePath.fill()
        context.restoreGState()
      } else {
        lineColor.setFill()
        linePath.fill()
      }
    }
  }

  private func drawInlineCode(in rect: CGRect) {
    let textStorage = self.textStorage
    guard textStorage.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.inlineCode, in: fullRange, options: []) { value, range, _ in
      guard (value as? Bool) == true else { return }
      guard let inlineRect = codeBlockRect(for: range, style: inlineCodeStyle, tight: true),
            inlineRect.intersects(rect)
      else { return }
      let backgroundColor = (textStorage.attribute(.inlineCodeBackground, at: range.location, effectiveRange: nil)
        as? UIColor) ?? UIColor.label.withAlphaComponent(0.12)
      let path = UIBezierPath(roundedRect: inlineRect, cornerRadius: inlineCodeStyle.cornerRadius)
      backgroundColor.setFill()
      path.fill()
    }
  }

  private func codeBlockRect(for range: NSRange, style: CodeBlockStyle, tight: Bool) -> CGRect? {
    let layoutManager = self.layoutManager
    let textContainer = self.textContainer
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return nil }

    layoutManager.ensureLayout(forCharacterRange: range)

    let rect: CGRect
    if tight {
      var bounding = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
      bounding.origin.x += textContainerInset.left - contentOffset.x
      bounding.origin.y += textContainerInset.top - contentOffset.y
      rect = bounding
    } else {
      var unionRect: CGRect?
      layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
        var fragment = usedRect
        fragment.origin.x += self.textContainerInset.left - self.contentOffset.x
        fragment.origin.y += self.textContainerInset.top - self.contentOffset.y
        unionRect = unionRect?.union(fragment) ?? fragment
      }

      var computed = unionRect ?? layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
      if unionRect == nil {
        computed.origin.x += textContainerInset.left - contentOffset.x
        computed.origin.y += textContainerInset.top - contentOffset.y
      }
      rect = computed
    }

    var padded = rect
    padded.origin.x -= style.textInsetLeft
    padded.size.width += style.textInsetLeft + style.textInsetRight
    padded.origin.y -= style.verticalPadding
    padded.size.height += style.verticalPadding * 2

    let insetBounds = bounds.insetBy(dx: style.blockHorizontalInset, dy: 0)
    let clipped = padded.intersection(insetBounds)
    return clipped.isNull ? nil : clipped
  }
}

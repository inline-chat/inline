import Foundation
import InlineMath
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension RichTextMath {
  /// Apply only after slicing and styling a canonical block/cell. Wire offsets
  /// continue addressing the original source; unrelated attributes move with
  /// their text when an opaque formula becomes one attachment character.
  public static func projectInline(
    _ text: NSAttributedString, sourceOffset: Int, snapshot: Snapshot, maximumWidth: CGFloat? = nil
  ) -> NSAttributedString {
    guard text.length > 0, text.length <= 131_072, sourceOffset >= 0,
          sourceOffset <= Int.max - text.length else { return text }
    var replacements: [(NSRange, Request, Image, CGFloat)] = []
    text.enumerateAttribute(.richTextMath, in: NSRange(location: 0, length: text.length)) { value, range, stop in
      let sourceRange = NSRange(location: sourceOffset + range.location, length: range.length)
      guard (value as? NSValue)?.rangeValue == sourceRange,
            let (request, image) = snapshot.inlineResult(for: sourceRange),
            request.tex.utf8.elementsEqual((text.string as NSString).substring(with: range).utf8) else { return }
      let scale: CGFloat
      if let maximumWidth {
        guard maximumWidth.isFinite, maximumWidth > 0 else { return }
        scale = min(1, maximumWidth / max(1, image.width))
      } else { scale = 1 }
      // An indivisible formula must not clip or shrink into unreadable pixels.
      // Very wide inline formulas keep their wrappable source; display math
      // and table cells have dedicated horizontal overflow surfaces.
      guard scale == 1 || request.pointSize * Double(scale) >= 8 else { return }
      replacements.append((range, request, image, scale))
      if replacements.count >= maximumFormulas { stop.pointee = true }
    }
    guard !replacements.isEmpty,
          MathTextProjection(source: text.string, renderedRanges: replacements.map(\.0)) != nil
    else { return text }
    let result = NSMutableAttributedString(attributedString: text)
    for (range, request, image, scale) in replacements.reversed() {
      var attributes = text.attributes(at: range.location, effectiveRange: nil)
      attributes.removeValue(forKey: .richTextMath)
      attributes.removeValue(forKey: .richTextMathDisplay)
      attributes[.attachment] = RichTextMathAttachment(request: request, image: image, scale: scale)
      result.replaceCharacters(in: range, with: NSAttributedString(string: "\u{fffc}", attributes: attributes))
    }
    return result
  }

  public static func containsRenderedMath(_ text: NSAttributedString, range: NSRange? = nil) -> Bool {
    let range = range ?? NSRange(location: 0, length: text.length)
    guard valid(range, length: text.length) else { return false }
    var found = false
    text.enumerateAttribute(.attachment, in: range) { value, _, stop in
      if value is RichTextMathAttachment { found = true; stop.pointee = true }
    }
    return found
  }

  /// Shared by native copy/accessibility and selection restoration. Ordinary
  /// strings and other attachment kinds remain untouched.
  public static func sourceProjection(_ text: NSAttributedString) -> MathTextProjection? {
    guard text.length <= 131_072 else { return nil }
    let original = text.string as NSString
    var source = "", ranges: [NSRange] = [], previous = 0, sourceLength = 0
    guard let occurrences = attachmentOccurrences(text) else { return nil }
    for (range, attachment) in occurrences {
      let prefix = original.substring(with: NSRange(location: previous, length: range.location - previous))
      source.append(prefix)
      sourceLength += (prefix as NSString).length
      let length = (attachment.request.tex as NSString).length
      guard length <= 131_072 - sourceLength else { return nil }
      ranges.append(NSRange(location: sourceLength, length: length))
      source.append(attachment.request.tex)
      sourceLength += length
      previous = NSMaxRange(range)
    }
    guard original.length - previous <= 131_072 - sourceLength else { return nil }
    source.append(original.substring(from: previous))
    return MathTextProjection(source: source, renderedRanges: ranges)
  }

  public static func sourceText(_ text: NSAttributedString, range: NSRange? = nil) -> String? {
    sourceProjection(text)?.sourceText(forDisplayRange: range ?? NSRange(location: 0, length: text.length))
  }

  /// Expand selected math into attributed TeX for native plain text, RTF/RTFD
  /// and HTML export. Surrounding links and formatting remain ordinary runs.
  public static func sourceAttributedText(_ text: NSAttributedString, range: NSRange) -> NSAttributedString? {
    guard sourceProjection(text)?.sourceRange(forDisplayRange: range) != nil else { return nil }
    let selected = text.attributedSubstring(from: range)
    let result = NSMutableAttributedString(string: "")
    var previous = 0
    guard let occurrences = attachmentOccurrences(selected) else { return nil }
    for (range, attachment) in occurrences {
      result.append(selected.attributedSubstring(from: NSRange(location: previous, length: range.location - previous)))
      var attributes = selected.attributes(at: range.location, effectiveRange: nil)
      attributes.removeValue(forKey: .attachment)
      attributes[.richTextMath] = NSValue(range: NSRange(location: result.length, length: (attachment.request.tex as NSString).length))
      if attachment.request.display { attributes[.richTextMathDisplay] = true }
      result.append(NSAttributedString(string: attachment.request.tex, attributes: attributes))
      previous = NSMaxRange(range)
    }
    result.append(selected.attributedSubstring(from: NSRange(location: previous, length: selected.length - previous)))
    return result
  }

  /// Readiness/appearance changes retain the same canonical selection, including
  /// selections whose endpoints were inside a now-rendered formula.
  public static func remapSelection(_ range: NSRange, from old: NSAttributedString, to new: NSAttributedString) -> NSRange? {
    guard let before = sourceProjection(old), let after = sourceProjection(new),
          before.source.utf8.elementsEqual(after.source.utf8),
          let sourceRange = before.sourceRange(forDisplayRange: range) else { return nil }
    return after.displayRange(forSourceRange: sourceRange)
  }

  private static func attachmentOccurrences(_ text: NSAttributedString) -> [(NSRange, RichTextMathAttachment)]? {
    var result: [(NSRange, RichTextMathAttachment)] = [], valid = true
    let source = text.string as NSString
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, stop in
      guard let attachment = value as? RichTextMathAttachment else { return }
      guard range.length <= maximumFormulas - result.count else { valid = false; stop.pointee = true; return }
      // Foundation coalesces equal adjacent attachment values. Each UTF-16
      // replacement character is still a distinct formula occurrence.
      for offset in range.location..<NSMaxRange(range) {
        guard source.character(at: offset) == 0xFFFC else { valid = false; stop.pointee = true; return }
        result.append((NSRange(location: offset, length: 1), attachment))
      }
    }
    return valid ? result : nil
  }

  private static func valid(_ range: NSRange, length: Int) -> Bool {
    range.location >= 0 && range.length >= 0 && range.location <= length && range.length <= length - range.location
  }
}

/// Equality describes immutable render inputs, so equivalent layout passes do
/// not reset native text selection merely because they created a new wrapper.
private final class RichTextMathAttachment: NSTextAttachment {
  let request: MathRenderRequest
  private let renderScale: CGFloat

  init(request: MathRenderRequest, image: MathImage, scale: CGFloat) {
    self.request = request
    renderScale = scale
    super.init(data: Data(request.tex.utf8), ofType: "public.utf8-plain-text")
    #if os(macOS)
    self.image = NSImage(cgImage: image.image, size: CGSize(width: image.width, height: image.height))
    self.image?.accessibilityDescription = request.tex
    #else
    self.image = UIImage(cgImage: image.image, scale: image.scale, orientation: .up)
    #endif
    bounds = CGRect(x: 0, y: -image.descent * scale, width: image.width * scale, height: image.height * scale)
  }

  required init?(coder: NSCoder) { return nil }

  override var hash: Int {
    var hasher = Hasher(); hasher.combine(request); hasher.combine(renderScale)
    return hasher.finalize()
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? RichTextMathAttachment else { return false }
    return request == other.request && renderScale == other.renderScale
  }
}

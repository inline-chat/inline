import Foundation
import InlineProtocol

/// Bounded scanning for the additive styles. Existing code and link parsing runs first.
enum InlineStyleMarkdown {
  struct Match {
    let entityType: MessageEntity.TypeEnum
    let opening: NSRange
    let content: NSRange
    let closing: NSRange
  }

  private static let literalHTMLExpression = try? NSRegularExpression(
    pattern: #"</?[A-Za-z][A-Za-z0-9:-]*(?=[\s/>])(?:[^<>"']|"[^"]*"|'[^']*')*>"#
  )
  private static let literalHTMLDelimiters = [("<!--", "-->"), ("<?", "?>"), ("<![CDATA[", "]]>")]
  private static let allowedTags: Set<String> = [
    "<b>", "</b>", "<i>", "</i>", "<u>", "</u>", "<s>", "</s>", "<mark>", "</mark>",
  ]

  /// Exact formatting tags are syntax; other HTML tokens stay literal.
  /// The source scanner decides whether an earlier code or math opener owns them.
  static func literalHTMLTokenEnd(in text: String, at start: Int, end: Int) -> Int? {
    let nsText = text as NSString
    guard start >= 0, start < end, end <= nsText.length, nsText.character(at: start) == 60 else { return nil }
    for (open, close) in literalHTMLDelimiters {
      let count = open.utf16.count
      guard start + count <= end, nsText.substring(with: NSRange(location: start, length: count)) == open else { continue }
      let range = nsText.range(of: close, range: NSRange(location: start + count, length: end - start - count))
      return range.location == NSNotFound ? end : NSMaxRange(range)
    }
    if start + 2 < end, nsText.character(at: start + 1) == 33, (65 ... 90).contains(nsText.character(at: start + 2)) {
      let range = nsText.range(of: ">", range: NSRange(location: start + 3, length: end - start - 3))
      return range.location == NSNotFound ? end : NSMaxRange(range)
    }
    guard let match = literalHTMLExpression?.firstMatch(
            in: text, options: [.anchored], range: NSRange(location: start, length: end - start)
          ),
          !allowedTags.contains(nsText.substring(with: match.range))
    else { return nil }
    return NSMaxRange(match.range)
  }

  static func matches(in text: String, codeRanges: [NSRange]) -> [Match] {
    let units = Array(text.utf16)
    let definitions: [(MessageEntity.TypeEnum, [UInt16], [UInt16])] = [
      (.bold, Array("<b>".utf16), Array("</b>".utf16)),
      (.italic, Array("<i>".utf16), Array("</i>".utf16)),
      (.underline, Array("<u>".utf16), Array("</u>".utf16)),
      (.strikethrough, Array("<s>".utf16), Array("</s>".utf16)),
      (.highlight, Array("<mark>".utf16), Array("</mark>".utf16)),
      (.strikethrough, Array("~~".utf16), Array("~~".utf16)),
      (.highlight, Array("==".utf16), Array("==".utf16)),
    ]
    let htmlRanges = InlineMathMarkdown.literalHTMLRanges(in: text, protectedRanges: codeRanges)
    var protectedRanges: [NSRange] = []
    for range in (codeRanges + htmlRanges).filter({
      $0.location >= 0 && $0.location <= units.count && $0.length > 0 && $0.length <= units.count - $0.location
    }).sorted(by: { $0.location < $1.location }) {
      if let last = protectedRanges.last, range.location <= NSMaxRange(last) {
        protectedRanges[protectedRanges.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
      } else {
        protectedRanges.append(range)
      }
    }
    func protectedEnd(at position: Int) -> Int? {
      var low = 0, high = protectedRanges.count
      while low < high {
        let middle = (low + high) / 2
        if protectedRanges[middle].location <= position { low = middle + 1 } else { high = middle }
      }
      guard low > 0, NSLocationInRange(position, protectedRanges[low - 1]) else { return nil }
      return NSMaxRange(protectedRanges[low - 1])
    }
    func has(_ marker: [UInt16], at position: Int, end: Int) -> Bool {
      guard position + marker.count <= end,
            units[position ..< position + marker.count].elementsEqual(marker)
      else { return false }
      if marker.count == 2 {
        if position > 0, units[position - 1] == marker[0] { return false }
        if position + 2 < units.count, units[position + 2] == marker[0] { return false }
      }
      return true
    }
    func read(at start: Int, end: Int, definition: (MessageEntity.TypeEnum, [UInt16], [UInt16])) -> Match? {
      let (entityType, opening, closing) = definition
      guard has(opening, at: start, end: end) else { return nil }
      var cursor = start + opening.count
      var nesting = 1
      while cursor < end {
        if let next = protectedEnd(at: cursor) { cursor = next; continue }
        if units[cursor] == 92 { cursor += 2; continue }
        if units[cursor] == 10 {
          var next = cursor + 1
          while next < end, units[next] == 32 || units[next] == 9 || units[next] == 13 { next += 1 }
          if next < end, units[next] == 10 { return nil }
        }
        if opening != closing, has(opening, at: cursor, end: end) {
          nesting += 1
          guard nesting <= 32 else { return nil }
          cursor += opening.count
          continue
        }
        if has(closing, at: cursor, end: end) {
          nesting -= 1
          if nesting == 0 {
            let contentStart = start + opening.count
            let content = String(decoding: units[contentStart ..< cursor], as: UTF16.self)
            guard !content.isEmpty,
                  opening != closing || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return Match(
              entityType: entityType,
              opening: NSRange(location: start, length: opening.count),
              content: NSRange(location: contentStart, length: cursor - contentStart),
              closing: NSRange(location: cursor, length: closing.count)
            )
          }
          cursor += closing.count
          continue
        }
        cursor += 1
      }
      return nil
    }

    var result: [Match] = []
    func scan(start: Int, end: Int, depth: Int) {
      guard depth < 32 else { return }
      var cursor = start
      while cursor < end {
        if let next = protectedEnd(at: cursor) { cursor = next; continue }
        if units[cursor] == 92 { cursor += 2; continue }
        if let match = definitions.lazy.compactMap({ read(at: cursor, end: end, definition: $0) }).first {
          result.append(match)
          scan(start: match.content.location, end: NSMaxRange(match.content), depth: depth + 1)
          cursor = NSMaxRange(match.closing)
        } else {
          cursor += 1
        }
      }
    }
    scan(start: 0, end: units.count, depth: 0)
    return result
  }
}

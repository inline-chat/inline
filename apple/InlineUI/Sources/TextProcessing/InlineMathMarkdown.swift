import Foundation

/// Source-only recognition shared by compose extraction. No TeX interpretation or rendering.
/// Offsets and limits match the server's UTF-16 math contract.
enum InlineMathMarkdown {
  // Same literal URL boundary as translation2/entities/url.ts. Only the math
  // opener is excluded: a formula may still contain a URL in its opaque body.
  private static let literalURLPattern = try! NSRegularExpression(
    pattern: #"\b(?:https?://|www\.)[^\s<>()]+(?:\([^\s<>()]*\)[^\s<>()]*)*"#,
    options: [.caseInsensitive]
  )

  struct Match {
    let range: NSRange
    let content: NSRange
    let display: Bool
    /// Double-dollar syntax that occupies its whole source line.
    let blockDisplay: Bool

    var isSupported: Bool { content.length <= (display ? 8_192 : 2_048) }
  }

  static func matches(in text: String, protectedRanges: [NSRange]) -> [Match] {
    guard text.contains("$") else { return [] }
    return scan(in: text, protectedRanges: protectedRanges).math
  }

  static func literalHTMLRanges(in text: String, protectedRanges: [NSRange]) -> [NSRange] {
    guard text.contains("<") else { return [] }
    return scan(in: text, protectedRanges: protectedRanges).literalHTML
  }

  private static func scan(in text: String, protectedRanges: [NSRange]) -> (math: [Match], literalHTML: [NSRange]) {
    let units = Array(text.utf16)
    let literalURLs = text.contains("$")
      ? literalURLPattern.matches(in: text, range: NSRange(location: 0, length: units.count)).map(\.range) : []
    var result: [Match] = []
    var literalHTML: [NSRange] = []

    func htmlEnd(at start: Int, end: Int) -> Int? {
      guard units[start] == 60 else { return nil }
      return InlineStyleMarkdown.literalHTMLTokenEnd(in: text, at: start, end: end)
    }

    func isWhitespace(_ unit: UInt16) -> Bool {
      // ECMAScript whitespace, also used by the server recognizer.
      (9 ... 13).contains(unit) || unit == 32 || unit == 160 || unit == 0x1680
        || (0x2000 ... 0x200A).contains(unit) || unit == 0x2028 || unit == 0x2029
        || unit == 0x202F || unit == 0x205F || unit == 0x3000 || unit == 0xFEFF
    }
    func escaped(_ position: Int) -> Bool {
      var cursor = position
      while cursor > 0, units[cursor - 1] == 92 { cursor -= 1 }
      return (position - cursor) % 2 == 1
    }
    func candidate(at start: Int, end: Int) -> Match? {
      guard units[start] == 36, !escaped(start),
            !literalURLs.contains(where: { NSLocationInRange(start, $0) }),
            !(start > 0 && units[start - 1] == 36 && !escaped(start - 1))
      else { return nil }
      let display = start + 1 < end && units[start + 1] == 36
      let count = display ? 2 : 1
      let contentStart = start + count
      guard contentStart < end, units[contentStart] != 36,
            display || !isWhitespace(units[contentStart])
      else { return nil }
      var cursor = contentStart
      while cursor < end {
        if units[cursor] == 36, !display || (cursor + 1 < end && units[cursor + 1] == 36) {
          let next = cursor + count
          guard !(next < end && units[next] == 36),
                display || (!isWhitespace(units[cursor - 1]) && !(next < end && (48 ... 57).contains(units[next]))),
                units[contentStart ..< cursor].contains(where: { !isWhitespace($0) })
          else { return nil }
          var lineStart = start
          while lineStart > 0, units[lineStart - 1] != 10, units[lineStart - 1] != 13 { lineStart -= 1 }
          var lineEnd = next
          while lineEnd < end, units[lineEnd] != 10, units[lineEnd] != 13 { lineEnd += 1 }
          let prefix = units[lineStart ..< start]
          let suffix = units[next ..< lineEnd]
          return Match(
            range: NSRange(location: start, length: next - start),
            content: NSRange(location: contentStart, length: cursor - contentStart),
            display: display,
            blockDisplay: display && prefix.count <= 3 && prefix.allSatisfy { $0 == 32 }
              && suffix.allSatisfy(isWhitespace)
          )
        }
        if !display, units[cursor] == 10 || units[cursor] == 13 { return nil }
        cursor += units[cursor] == 92 ? 2 : 1
      }
      return nil
    }
    func protectedEnd(at position: Int) -> Int? {
      protectedRanges.first { NSLocationInRange(position, $0) }.map(NSMaxRange)
    }
    func runEnd(at start: Int, end: Int) -> Int {
      var cursor = start + 1
      while cursor < end, units[cursor] == units[start] { cursor += 1 }
      return cursor
    }
    func codeEnd(at start: Int, end: Int) -> Int? {
      guard units[start] == 96 || units[start] == 126 else { return nil }
      let openingEnd = runEnd(at: start, end: end)
      let count = openingEnd - start
      var lineStart = start
      while lineStart > 0, units[lineStart - 1] != 10, units[lineStart - 1] != 13 { lineStart -= 1 }
      var openingLineEnd = openingEnd
      while openingLineEnd < end, units[openingLineEnd] != 10, units[openingLineEnd] != 13 { openingLineEnd += 1 }
      let fenced = count >= 3 && start - lineStart <= 3 && units[lineStart ..< start].allSatisfy { $0 == 32 }
        && (units[start] != 96 || !units[openingEnd ..< openingLineEnd].contains(96))
      guard units[start] == 96 || fenced else { return nil }
      var cursor = openingEnd
      while cursor < end {
        if units[cursor] == units[start] {
          let next = runEnd(at: cursor, end: end)
          if fenced {
            var closeLineStart = cursor
            while closeLineStart > 0, units[closeLineStart - 1] != 10, units[closeLineStart - 1] != 13 { closeLineStart -= 1 }
            var lineEnd = next
            while lineEnd < end, units[lineEnd] == 32 || units[lineEnd] == 9 { lineEnd += 1 }
            if next - cursor >= count, cursor - closeLineStart <= 3,
               units[closeLineStart ..< cursor].allSatisfy({ $0 == 32 }),
               lineEnd == end || units[lineEnd] == 10 || units[lineEnd] == 13
            { return lineEnd }
          } else if next - cursor == count {
            return next
          }
          cursor = next
        } else {
          if !fenced, units[cursor] == 10 || units[cursor] == 13 { return nil }
          cursor += 1
        }
      }
      return fenced ? end : nil
    }
    func link(at start: Int, end: Int) -> (labelEnd: Int, end: Int)? {
      guard units[start] == 91 else { return nil }
      var cursor = start + 1
      var depth = 1
      while cursor < end {
        if let next = protectedEnd(at: cursor) { cursor = next; continue }
        if units[cursor] == 92 { cursor += 2; continue }
        if let next = htmlEnd(at: cursor, end: end) { cursor = next; continue }
        if let next = codeEnd(at: cursor, end: end) { cursor = next; continue }
        if let math = candidate(at: cursor, end: end) { cursor = NSMaxRange(math.range); continue }
        if units[cursor] == 91 {
          depth += 1
          guard depth <= 32 else { return nil }
        } else if units[cursor] == 93 {
          depth -= 1
          if depth == 0 { break }
        }
        cursor += 1
      }
      guard cursor + 1 < end, units[cursor + 1] == 40 else { return nil }
      let labelEnd = cursor
      cursor += 2
      depth = 1
      while cursor < end {
        if units[cursor] == 92 { cursor += 2; continue }
        if units[cursor] == 40 { depth += 1 }
        if units[cursor] == 41 {
          depth -= 1
          if depth == 0 { return (labelEnd, cursor + 1) }
        }
        cursor += 1
      }
      return nil
    }
    func scan(start: Int, end: Int, depth: Int) {
      guard depth < 32 else { return }
      var cursor = start
      while cursor < end {
        if let next = protectedEnd(at: cursor) { cursor = next; continue }
        if units[cursor] == 92 { cursor += 2; continue }
        if let next = htmlEnd(at: cursor, end: end) {
          literalHTML.append(NSRange(location: cursor, length: next - cursor))
          cursor = next
          continue
        }
        if let next = codeEnd(at: cursor, end: end) { cursor = next; continue }
        if let link = link(at: cursor, end: end) {
          scan(start: cursor + 1, end: link.labelEnd, depth: depth + 1)
          cursor = link.end
          continue
        }
        if let math = candidate(at: cursor, end: end) {
          // Restored opaque source wins over typed syntax crossing it.
          if !protectedRanges.contains(where: { NSIntersectionRange($0, math.range).length > 0 }) {
            result.append(math)
          }
          cursor = NSMaxRange(math.range)
          continue
        }
        cursor += 1
      }
    }
    scan(start: 0, end: units.count, depth: 0)
    return (result, literalHTML)
  }
}

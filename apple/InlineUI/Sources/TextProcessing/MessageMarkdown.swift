import Foundation
import InlineKit
import InlineProtocol

/// Converts displayed message formatting back into editable composer syntax.
public enum MessageMarkdown {
  public static func string(from attributedString: NSAttributedString) -> String {
    let extracted = ProcessEntities.fromAttributedString(normalizedText(attributedString), parseMarkdown: false)
    return string(text: extracted.text, entities: extracted.entities)
  }

  static func normalizedText(_ attributedString: NSAttributedString) -> NSAttributedString {
    let normalized = NSMutableAttributedString(attributedString: attributedString)
    let fullRange = NSRange(location: 0, length: normalized.length)
    attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
      // Rich text from other apps has native decorations rather than Inline's semantic markers.
      // Link underlines are normally supplied by the source app's theme.
      if attributes[.link] == nil,
         let underline = attributes[.underlineStyle] as? NSNumber, underline.intValue != 0 {
        normalized.addAttribute(.richTextUnderline, value: true, range: range)
      }
      if let strike = attributes[.strikethroughStyle] as? NSNumber, strike.intValue != 0 {
        normalized.addAttribute(.richTextStrikethrough, value: true, range: range)
      }
      if attributes[.inlineCode] == nil, attributes[.preCode] == nil, attributes[.richTextMath] == nil,
         let font = attributes[.font] as? PlatformFont, ProcessEntities.isMonospaceFont(font) {
        let text = (attributedString.string as NSString).substring(with: range)
        normalized.addAttribute(text.contains("\n") ? .preCode : .inlineCode, value: true, range: range)
      }
    }
    return normalized
  }

  public static func string(text: String, entities: MessageEntities?) -> String {
    serializedText(NSAttributedString(string: text), entities: entities, markerAttributes: [:]).string
  }

  /// Loads editable syntax while retaining identities attached to mentions and thread labels.
  public static func editableText(
    text: String,
    entities: MessageEntities?,
    configuration: ProcessEntities.Configuration
  ) -> NSAttributedString {
    let semanticEntities = MessageEntities.with {
      $0.entities = entities?.entities.filter { !isEditableSyntax($0.type) } ?? []
    }
    let syntaxEntities = MessageEntities.with {
      $0.entities = entities?.entities.filter { isEditableSyntax($0.type) } ?? []
    }
    let source = ProcessEntities.toAttributedString(
      text: text,
      entities: semanticEntities,
      configuration: configuration
    )
    return serializedText(source, entities: syntaxEntities, markerAttributes: [
      .font: configuration.font,
      .foregroundColor: configuration.primaryColor,
    ])
  }

  private static func isEditableSyntax(_ type: MessageEntity.TypeEnum) -> Bool {
    switch type {
    case .bold, .italic, .underline, .strikethrough, .highlight, .code, .pre, .math, .textURL: true
    default: false
    }
  }

  private static func serializedText(
    _ original: NSAttributedString,
    entities: MessageEntities?,
    markerAttributes: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    let text = original.string
    guard let entities, !entities.entities.isEmpty, !text.isEmpty else { return original }
    let source = text as NSString
    var spans = entities.entities.compactMap { span(for: $0, in: text) }
    guard !spans.isEmpty else { return original }

    // Native font runs can split one style at every nested attribute boundary.
    // Joining those runs also prevents adjacent identical delimiters from becoming ambiguous.
    spans.sort {
      if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
      return $0.range.length > $1.range.length
    }
    var merged: [Span] = []
    for span in spans {
      if let index = merged.lastIndex(where: {
        $0.kind == span.kind && NSMaxRange($0.range) >= span.range.location
      }) {
        merged[index].range.length = max(NSMaxRange(merged[index].range), NSMaxRange(span.range))
          - merged[index].range.location
      } else {
        merged.append(span)
      }
    }
    spans = merged.flatMap { span -> [Span] in
      if span.kind.isOpaque { return [span] }
      if case .link = span.kind { return [span] }
      // Inline formatting cannot enclose paragraph breaks in the composer grammar.
      // Retain every original newline outside the adjacent style delimiters.
      var segments: [Span] = []
      var start = span.range.location
      for position in span.range.location ..< NSMaxRange(span.range) where source.character(at: position) == 10
        || source.character(at: position) == 13 {
        if position > start { segments.append(Span(range: NSRange(location: start, length: position - start), kind: span.kind)) }
        start = position + 1
      }
      if start < NSMaxRange(span.range) {
        segments.append(Span(range: NSRange(location: start, length: NSMaxRange(span.range) - start), kind: span.kind))
      }
      return segments
    }

    let tokens = spans.map { token(for: $0, in: source, spans: spans) }
    let boundaries = Set([0, source.length] + spans.flatMap { [$0.range.location, NSMaxRange($0.range)] }).sorted()
    let result = NSMutableAttributedString(string: "")
    func appendMarker(_ marker: String, at offset: Int) {
      var attributes = markerAttributes
      if offset > 0, offset < original.length {
        let keys: [NSAttributedString.Key] = [
          .mentionUserId, .mentionAgentId, .mentionGroupId, .threadLink,
          .link, .botCommand, .botCommandTargetUserId, .emailAddress, .phoneNumber,
        ]
        let before = keys.reduce(into: [NSAttributedString.Key: AnyHashable]()) { values, key in
          values[key] = original.attribute(key, at: offset - 1, effectiveRange: nil) as? AnyHashable
        }
        let after = keys.reduce(into: [NSAttributedString.Key: AnyHashable]()) { values, key in
          values[key] = original.attribute(key, at: offset, effectiveRange: nil) as? AnyHashable
        }
        // Markers inside one semantic label must not split it into separate mentions on send.
        // Only identity attributes cross the inserted syntax; its font remains the composer font.
        if before == after {
          for key in before.keys { attributes[key] = original.attribute(key, at: offset, effectiveRange: nil) }
        }
      }
      result.append(NSAttributedString(string: marker, attributes: attributes))
    }
    var open: [Token] = []
    for (start, end) in zip(boundaries, boundaries.dropFirst()) {
      let active = spans.indices.filter { NSLocationInRange(start, spans[$0].range) }
      let opaque = active.first { spans[$0].kind.isOpaque }
      let visible = opaque.map { [$0] } ?? active
      let desired = visible.sorted {
        if spans[$0].kind.order != spans[$1].kind.order { return spans[$0].kind.order < spans[$1].kind.order }
        return spans[$0].range.location < spans[$1].range.location
      }.map { tokens[$0] }

      let common = zip(open, desired).prefix { $0 == $1 }.count
      for token in open.dropFirst(common).reversed() { appendMarker(token.closing, at: start) }
      for token in desired.dropFirst(common) { appendMarker(token.opening, at: start) }
      result.append(original.attributedSubstring(from: NSRange(location: start, length: end - start)))
      open = desired
    }
    for token in open.reversed() { appendMarker(token.closing, at: original.length) }
    return result
  }

  private enum Kind: Equatable {
    case link(String), bold, italic, underline, strike, highlight, code, pre, math(Bool)

    var order: Int {
      switch self {
      case .link: 0
      case .underline: 1
      case .strike: 2
      case .highlight: 3
      case .bold: 4
      case .italic: 5
      case .code: 6
      case .pre: 7
      case .math: 8
      }
    }

    var isOpaque: Bool {
      switch self {
      case .code, .pre, .math: true
      default: false
      }
    }
  }

  private struct Span {
    var range: NSRange
    let kind: Kind
  }

  private struct Token: Equatable {
    let opening: String
    let closing: String
  }

  private static func span(for entity: MessageEntity, in text: String) -> Span? {
    let count = text.utf16.count
    guard entity.offset >= 0, entity.length > 0,
          entity.offset <= count, entity.length <= Int64(count) - entity.offset
    else { return nil }
    let range = NSRange(location: Int(entity.offset), length: Int(entity.length))
    // NSRange-to-String conversion accepts some interior UTF16 offsets. Explicitly reject
    // a boundary inside a surrogate pair before NSString slicing can replace its halves.
    let utf16 = text as NSString
    guard isScalarBoundary(range.location, in: utf16),
          isScalarBoundary(NSMaxRange(range), in: utf16)
    else { return nil }
    let kind: Kind
    switch entity.type {
    case .bold: kind = .bold
    case .italic: kind = .italic
    case .underline: kind = .underline
    case .strikethrough: kind = .strike
    case .highlight: kind = .highlight
    case .code: kind = .code
    case .pre: kind = .pre
    case .math: kind = .math(entity.math.display)
    case .textURL:
      guard !entity.textURL.url.isEmpty else { return nil }
      kind = .link(entity.textURL.url)
    case .mention:
      guard entity.mention.userID > 0 else { return nil }
      var target = "inline://user/\(entity.mention.userID)"
      if entity.mention.hasAgentID { target += "?agent_id=\(entity.mention.agentID)" }
      kind = .link(target)
    case .thread:
      guard entity.thread.chatID > 0 else { return nil }
      kind = .link("inline://chat/\(entity.thread.chatID)")
    case .threadTitle:
      var target = URLComponents()
      target.scheme = "inline"
      target.host = "thread"
      target.queryItems = [
        URLQueryItem(name: "space_id", value: String(entity.threadTitle.spaceID)),
        URLQueryItem(name: "title", value: entity.threadTitle.title),
      ]
      guard let url = target.string else { return nil }
      kind = .link(url)
    default:
      // Auto-detected URLs, phone numbers, emails and commands already carry their visible syntax.
      return nil
    }
    return Span(range: range, kind: kind)
  }

  private static func token(for span: Span, in text: NSString, spans: [Span]) -> Token {
    let content = text.substring(with: span.range)
    let overlaps = spans.contains {
      $0.kind != span.kind && NSIntersectionRange($0.range, span.range).length > 0
    }
    switch span.kind {
    case let .link(url):
      // Parentheses are legal in URLs, but unbalanced ones would terminate Markdown early.
      let destination = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
      return Token(opening: "[", closing: "](\(destination))")
    case .bold:
      return content.contains("**") ? Token(opening: "<b>", closing: "</b>") : Token(opening: "**", closing: "**")
    case .italic:
      let start = span.range.location
      let end = NSMaxRange(span.range)
      let leadingBoundary = start == 0 || isWhitespace(text.character(at: start - 1))
      let trailingBoundary = end == text.length || isWhitespace(text.character(at: end))
      // The current composer parser intentionally avoids underscores inside identifiers.
      if !overlaps, leadingBoundary, trailingBoundary, !content.contains("_"), !content.contains("\n") {
        return Token(opening: "_", closing: "_")
      }
      return Token(opening: "<i>", closing: "</i>")
    case .underline:
      return Token(opening: "<u>", closing: "</u>")
    case .strike:
      return overlaps || content.contains("~~")
        ? Token(opening: "<s>", closing: "</s>") : Token(opening: "~~", closing: "~~")
    case .highlight:
      return overlaps || content.contains("==")
        ? Token(opening: "<mark>", closing: "</mark>") : Token(opening: "==", closing: "==")
    case .code:
      let requiredLength = max(1, longestBacktickRun(in: content) + 1)
      // Inline's existing three-backtick syntax means a block even without newlines.
      let fence = String(repeating: "`", count: requiredLength == 3 ? 4 : requiredLength)
      let needsPadding = content.hasPrefix("`") || content.hasSuffix("`")
        || (content.hasPrefix(" ") && content.hasSuffix(" ") && !content.allSatisfy { $0 == " " })
      return Token(opening: fence + (needsPadding ? " " : ""), closing: (needsPadding ? " " : "") + fence)
    case .pre:
      let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: content) + 1))
      return Token(opening: fence + "\n", closing: "\n" + fence)
    case let .math(display):
      return display ? Token(opening: "$$", closing: "$$") : Token(opening: "$", closing: "$")
    }
  }

  private static func isWhitespace(_ unit: UInt16) -> Bool {
    UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
  }

  private static func isScalarBoundary(_ offset: Int, in text: NSString) -> Bool {
    guard offset > 0, offset < text.length else { return true }
    return !(0xD800 ... 0xDBFF).contains(text.character(at: offset - 1))
      || !(0xDC00 ... 0xDFFF).contains(text.character(at: offset))
  }

  private static func longestBacktickRun(in text: String) -> Int {
    var longest = 0
    var run = 0
    for character in text {
      run = character == "`" ? run + 1 : 0
      longest = max(longest, run)
    }
    return longest
  }
}

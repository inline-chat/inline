import Foundation
import InlineProtocol

/// A reply that quotes part of the replied message, shown like Telegram: the quote sits in
/// the reply header and the body is the caption.
public struct ReplyQuote: Sendable {
  /// Quoted text for the reply header.
  public let text: String
  /// For a reply sent with its quote inside the text: the blocks after the quote. Their
  /// ranges still index the full message text. Nil when the text is already just the caption.
  public let body: InlineProtocol.BlockContent?
  public let bodyCacheSignature: Int?
  public let bodyByteCount: Int?
}

public extension ReplyQuote {
  /// Where `quote` sits in `text`, for highlighting it in the replied message: the whole
  /// quote, else its first line through its last, else its first line. Quote lines are
  /// joined with one newline while the source may separate them with blank lines.
  static func range(of quote: String, in text: String) -> NSRange? {
    let source = text as NSString
    let whole = source.range(of: quote)
    if whole.location != NSNotFound, whole.length > 0 { return whole }

    let lines = quote.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard let first = lines.first else { return nil }
    let start = source.range(of: first)
    guard start.location != NSNotFound else { return nil }
    if lines.count > 1, let last = lines.last {
      let after = NSMaxRange(start)
      let end = source.range(of: last, range: NSRange(location: after, length: source.length - after))
      if end.location != NSNotFound { return NSUnionRange(start, end) }
    }
    return start
  }
}

public extension Message {
  /// The quote of a reply, or nil when the message is not a quote reply. Replies carry it
  /// apart from the caption; ones sent before that open their text with it instead.
  /// Reads stored values only; nothing is parsed or serialized.
  var replyQuote: ReplyQuote? {
    guard repliedToMessageId != nil else { return nil }
    if let replyQuoteText {
      return ReplyQuote(text: replyQuoteText, body: nil, bodyCacheSignature: nil, bodyByteCount: nil)
    }
    guard let text, let payload = blockContentPayload,
          payload.content.blocks.count > 1,
          case let .quote(quote)? = payload.content.blocks.first?.kind
    else { return nil }

    let source = text as NSString
    let quoted = quote.children.compactMap { child -> String? in
      guard case let .paragraph(range)? = child.kind, range.offset >= 0, range.length > 0,
            range.offset + range.length <= Int64(source.length) else { return nil }
      return source.substring(with: NSRange(location: Int(range.offset), length: Int(range.length)))
    }.joined(separator: "\n")
    guard !quoted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    var body = payload.content
    body.blocks.removeFirst()
    var hasher = Hasher()
    hasher.combine(payload.cacheSignature)
    hasher.combine("reply-quote-body")
    return ReplyQuote(
      text: quoted,
      body: body,
      bodyCacheSignature: hasher.finalize(),
      bodyByteCount: payload.byteCount
    )
  }
}

public extension ReplyQuote {
  /// What a reply sends when its text opens with a quote, as the composer's "> " lines make
  /// it: the quote apart, and the caption with its own entities. Nil when the text doesn't
  /// open with a quote or has no caption after it, which stays an ordinary message.
  static func split(
    text: String,
    entities: MessageEntities?
  ) -> (quote: String, caption: String, entities: MessageEntities?)? {
    let source = text as NSString
    guard let quoteEntity = entities?.entities.first(where: { $0.type == .blockquote && $0.offset == 0 }),
          quoteEntity.length > 0, Int(quoteEntity.length) <= source.length
    else { return nil }

    let quoteEnd = Int(quoteEntity.length)
    let quote = source.substring(to: quoteEnd).trimmingCharacters(in: .whitespacesAndNewlines)
    var captionStart = quoteEnd
    while captionStart < source.length,
          let scalar = UnicodeScalar(source.character(at: captionStart)),
          CharacterSet.whitespacesAndNewlines.contains(scalar)
    {
      captionStart += 1
    }
    let caption = source.substring(from: captionStart)
    guard !quote.isEmpty, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    // Styles inside the quote stay with it in the source message; the caption keeps its own.
    let shift = Int64(captionStart)
    let captionEntities = (entities?.entities ?? []).compactMap { entity -> MessageEntity? in
      guard entity.offset >= shift else { return nil }
      var moved = entity
      moved.offset -= shift
      return moved
    }
    return (
      quote,
      caption,
      captionEntities.isEmpty ? nil : MessageEntities.with { $0.entities = captionEntities }
    )
  }
}

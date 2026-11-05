import Foundation
import InlineProtocol

/// A reply that opens with a quote, shown like Telegram: the quote moves into the
/// reply header and the body renders only the blocks after it.
public struct ReplyQuote: Sendable {
  /// Quoted text for the reply header.
  public let text: String
  /// Blocks after the quote. Their ranges still index the full message text.
  public let body: InlineProtocol.BlockContent
  public let bodyCacheSignature: Int
  public let bodyByteCount: Int
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
  /// The leading quote of a reply, or nil when the message is not a quote reply.
  /// Reads the decoded blocks only; nothing is parsed or serialized.
  var replyQuote: ReplyQuote? {
    guard repliedToMessageId != nil, let text, let payload = blockContentPayload,
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

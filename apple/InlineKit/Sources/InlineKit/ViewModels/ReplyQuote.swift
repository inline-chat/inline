import Foundation
import InlineProtocol

public enum ReplyQuote {
  /// Where `quote` sits in `text`, for highlighting it in a message: the whole quote, else
  /// its first line through its last, else its first line. Quote lines are joined with one
  /// newline while the source may separate them with blank lines.
  public static func range(of quote: String, in text: String) -> NSRange? {
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

  /// The text after a message's opening quote, for previews that show a reply's caption
  /// rather than the words it quotes. Nil when the text doesn't open with a quote or nothing
  /// follows it, so the whole text shows instead.
  public static func caption(afterLeadingQuoteIn text: String, entities: MessageEntities?) -> String? {
    let source = text as NSString
    guard let quote = entities?.entities.first(where: { $0.type == .blockquote && $0.offset == 0 }),
          quote.length > 0, Int(quote.length) < source.length
    else { return nil }
    let caption = source.substring(from: Int(quote.length)).trimmingCharacters(in: .whitespacesAndNewlines)
    return caption.isEmpty ? nil : caption
  }
}

/// A reply's opening quote taken from the replied message, shown like Telegram: in the reply
/// header, with the body rendering only the blocks after it. Other quotes, including normal
/// "> " quotes, stay quote blocks in the body.
public struct LeadingReplyQuote: Sendable {
  /// Quoted text for the reply header.
  public let text: String
  /// Blocks after the quote. Their ranges still index the full message text.
  public let body: InlineProtocol.BlockContent
  public let bodyCacheSignature: Int
  public let bodyByteCount: Int
}

public extension LeadingReplyQuote {
  /// Shorter quotes ("ok") match almost any message, so they stay in the body.
  static let minimumLength = 3

  /// The opening quote of `message` when it counts as a reply quote: the message replies to
  /// `repliedText`, opens with a quote followed by more content, and the quoted words are in
  /// the replied message. Reads the decoded blocks only; nothing is parsed or serialized.
  init?(message: Message, repliedText: String?) {
    guard message.repliedToMessageId != nil, let repliedText, !repliedText.isEmpty,
          let text = message.text, let payload = message.blockContentPayload,
          payload.content.blocks.count > 1,
          case let .quote(quote)? = payload.content.blocks.first?.kind
    else { return nil }

    let source = text as NSString
    let quoted = quote.children.compactMap { child -> String? in
      guard case let .paragraph(range)? = child.kind, range.offset >= 0, range.length > 0,
            range.offset + range.length <= Int64(source.length) else { return nil }
      return source.substring(with: NSRange(location: Int(range.offset), length: Int(range.length)))
    }.joined(separator: "\n")
    let visible = quoted.filter { !$0.isWhitespace }
    guard visible.count >= Self.minimumLength,
          ReplyQuote.range(of: quoted, in: repliedText) != nil
    else { return nil }

    var body = payload.content
    body.blocks.removeFirst()
    var hasher = Hasher()
    hasher.combine(payload.cacheSignature)
    hasher.combine("leading-reply-quote-body")
    self.init(text: quoted, body: body, bodyCacheSignature: hasher.finalize(), bodyByteCount: payload.byteCount)
  }
}

public extension FullMessage {
  /// The reply quote shown in this message's reply header, if any.
  var leadingReplyQuote: LeadingReplyQuote? {
    LeadingReplyQuote(message: message, repliedText: repliedToMessage?.message.text)
  }
}

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

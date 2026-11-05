import Foundation

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
}

import Foundation

/// Best-effort removal of common sensitive values from free-form log text while keeping
/// the message useful for debugging. It cannot recognize arbitrary user content, so call
/// sites should still avoid interpolating message bodies, drafts, or names.
enum LogScrubber {
  static let maxLength = 1_000

  private struct Rule {
    let regex: NSRegularExpression
    let template: String

    init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
      // Patterns are static literals; a failure here is a programmer error caught by tests.
      regex = try! NSRegularExpression(pattern: pattern, options: options)
      self.template = template
    }
  }

  private static let rules: [Rule] = [
    // URLs: drop credentials, query, and fragment; keep scheme, host, and path.
    Rule(#"\b([a-zA-Z][a-zA-Z0-9+.\-]*://)(?:[^@/\s]+@)?([^/\s?#]+)([^\s?#]*)[?#][^\s"'<>)]*"#, "$1$2$3"),
    Rule(#"\b([a-zA-Z][a-zA-Z0-9+.\-]*://)[^@/\s]+@"#, "$1"),
    // Secrets introduced by a keyword, e.g. `token=…`, `Authorization: Bearer …`.
    Rule(
      #"\b(bearer|token|secret|password|passwd|authorization|api[_\-]?key|session[_\-]?key|cookie)(\s*[:=]\s*|\s+)(?:bearer\s+)?[^\s,;)"']+"#,
      "$1$2<redacted>",
      options: .caseInsensitive
    ),
    Rule(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, "<email>", options: .caseInsensitive),
    Rule(#"\+\d[\d\s().\-]{6,}\d"#, "<phone>"),
    // Home directory user names in file paths.
    Rule(#"/Users/[^/\s]+"#, "/Users/<user>"),
    // Long opaque values (tokens, keys, hashes). UUIDs and numeric IDs stay intact.
    Rule(#"[A-Za-z0-9_=]{32,}"#, "<redacted>"),
  ]

  static func scrub(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var result = text.count > maxLength * 2 ? String(text.prefix(maxLength * 2)) : text
    for rule in rules {
      let range = NSRange(result.startIndex..., in: result)
      result = rule.regex.stringByReplacingMatches(
        in: result,
        options: [],
        range: range,
        withTemplate: rule.template
      )
    }
    if result.count > maxLength {
      result = String(result.prefix(maxLength)) + "…"
    }
    return result
  }
}

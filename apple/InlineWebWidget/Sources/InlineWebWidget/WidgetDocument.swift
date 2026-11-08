import Foundation

/// A widget as stored in a message's block payload.
public struct WidgetContent: Hashable, Sendable {
  /// Message id + revision + widget id. Keys caches and the widget origin.
  public var key: String
  public var title: String
  public var html: String
  public var heightHint: Int?
  /// Bot-uploaded images, served at `media/<index>`.
  public var media: [Data]

  public init(key: String, title: String, html: String, heightHint: Int? = nil, media: [Data] = []) {
    self.key = key
    self.title = title
    self.html = html
    self.heightHint = heightHint
    self.media = media
  }
}

public enum WidgetDocument {
  public static let minHeight = 80
  public static let maxHeight = 2000

  /// Response header for every widget document. A `<meta>` in the widget can
  /// only tighten it.
  public static let contentSecurityPolicy = [
    "default-src 'none'",
    "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://unpkg.com https://esm.sh",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' data: https://fonts.gstatic.com",
    "img-src 'self' data: blob:",
    "media-src 'self' data: blob:",
    "connect-src 'none'",
    "frame-src 'none'",
    "child-src 'none'",
    "worker-src blob:",
    "form-action 'none'",
    "base-uri 'none'",
  ].joined(separator: "; ")

  public static func clampHeight(_ height: Int) -> Int {
    min(maxHeight, max(minHeight, height))
  }

  public static func isFullDocument(_ html: String) -> Bool {
    let head = html.prefix(2048).lowercased()
    return head.contains("<!doctype") || head.contains("<html") || head.contains("<head")
  }

  /// Wraps a fragment, or injects the runtime into a full document's head.
  public static func build(content: WidgetContent, theme: WidgetTheme, state: String?, context: [String: String]) -> String {
    let initJSON = initPayload(state: state, context: context)
    let injection = [
      "<meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "<style id=\"inline-theme\">\(theme.rootRule)</style>",
      "<link rel=\"stylesheet\" href=\"\(WidgetRuntime.cssPath)\">",
      "<script>window.__inlineInit=\(initJSON);</script>",
      "<script src=\"\(WidgetRuntime.scriptPath)\"></script>",
    ].joined()

    let html = content.html
    guard isFullDocument(html) else {
      return "<!doctype html><html><head>\(injection)<title>\(escapeText(content.title))</title></head><body>\(html)</body></html>"
    }
    if let range = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
      var result = html
      result.insert(contentsOf: injection, at: range.upperBound)
      return result
    }
    if let range = html.range(of: #"<html(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
      var result = html
      result.insert(contentsOf: "<head>\(injection)</head>", at: range.upperBound)
      return result
    }
    return "<!doctype html><head>\(injection)</head>\(html)"
  }

  static func initPayload(state: String?, context: [String: String]) -> String {
    let contextData = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])) ?? Data("{}".utf8)
    let contextJSON = String(decoding: contextData, as: UTF8.self)
    let stateJSON = state ?? "null"
    // `<` escaped so a value can never close the script element.
    return "{\"state\":\(stateJSON),\"context\":\(contextJSON)}".replacingOccurrences(of: "<", with: "\\u003c")
  }

  static func escapeText(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
  }

  /// Send-time checks from the spec that need no browser. Returns a message
  /// naming the first failing rule, or nil.
  public static func validate(_ html: String, maxBytes: Int = 256 * 1024) -> String? {
    if html.utf8.count > maxBytes { return "Widget HTML is \(html.utf8.count) bytes; the limit is \(maxBytes)." }
    let checks: [(String, String)] = [
      (#"(?<![\w.+/-])(\d+(\.\d+)?|\.\d+)[sld]?vh(?![\w-])"#, "vh units loop with auto height; use px."),
      (#"<\s*(iframe|object|embed)\b"#, "iframe, object and embed are not allowed."),
      (#"type\s*=\s*["']?password"#, "Password inputs are not allowed; use a native form secret field."),
    ]
    for (pattern, message) in checks {
      if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
        let line = html[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return "\(message) (line \(line))"
      }
    }
    return nil
  }
}

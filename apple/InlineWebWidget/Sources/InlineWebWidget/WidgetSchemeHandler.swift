import Foundation
import WebKit

/// How widget origins are assigned. Measured by the spike: a separate origin
/// per widget isolates storage but may cost a WebContent process per widget.
public enum WidgetOriginMode: String, Sendable {
  case perWidget = "per-widget"
  case shared
}

public enum WidgetURL {
  public static let scheme = "inline-widget"
  static let sharedHost = "w"

  public static func host(for key: String, mode: WidgetOriginMode) -> String {
    switch mode {
    case .perWidget: "w-" + sanitize(key)
    case .shared: sharedHost
    }
  }

  public static func documentURL(for key: String, mode: WidgetOriginMode) -> URL {
    switch mode {
    case .perWidget: URL(string: "\(scheme)://\(host(for: key, mode: mode))/index.html")!
    case .shared: URL(string: "\(scheme)://\(sharedHost)/\(sanitize(key))/index.html")!
    }
  }

  static func sanitize(_ key: String) -> String {
    String(key.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(60))
  }
}

/// Serves widget documents, the bundled runtime and bot media. Nothing here
/// touches the network.
@MainActor
public final class WidgetSchemeHandler: NSObject, WKURLSchemeHandler {
  struct Record {
    var document: Data
    var media: [Data]
  }

  /// Keyed by document directory URL ("inline-widget://host/" or ".../key/").
  private var records: [String: Record] = [:]
  public private(set) var servedRequests = 0

  public func register(content: WidgetContent, document: String, mode: WidgetOriginMode) {
    let base = WidgetURL.documentURL(for: content.key, mode: mode).deletingLastPathComponent().absoluteString
    records[base] = Record(document: Data(document.utf8), media: content.media)
  }

  public func unregister(key: String, mode: WidgetOriginMode) {
    records[WidgetURL.documentURL(for: key, mode: mode).deletingLastPathComponent().absoluteString] = nil
  }

  public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    servedRequests += 1
    guard let url = urlSchemeTask.request.url else { return fail(urlSchemeTask) }
    let path = url.path
    if path == WidgetRuntime.cssPath {
      return respond(urlSchemeTask, url: url, data: Data(WidgetRuntime.css.utf8), mime: "text/css", cacheable: true)
    }
    if path == WidgetRuntime.scriptPath {
      return respond(urlSchemeTask, url: url, data: Data(WidgetRuntime.script.utf8), mime: "text/javascript", cacheable: true)
    }
    let base = url.deletingLastPathComponent().absoluteString
    if url.lastPathComponent == "index.html", let record = records[base] {
      return respond(urlSchemeTask, url: url, data: record.document, mime: "text/html", csp: WidgetDocument.contentSecurityPolicy)
    }
    // media/<n> relative to the document directory.
    let parent = url.deletingLastPathComponent()
    if parent.lastPathComponent == "media", let index = Int(url.lastPathComponent),
       let record = records[parent.deletingLastPathComponent().absoluteString], record.media.indices.contains(index) {
      return respond(urlSchemeTask, url: url, data: record.media[index], mime: Self.imageMime(record.media[index]), cacheable: true)
    }
    fail(urlSchemeTask)
  }

  public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

  private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mime: String, csp: String? = nil, cacheable: Bool = false) {
    var headers = [
      "Content-Type": mime,
      "Content-Length": String(data.count),
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": cacheable ? "max-age=86400" : "no-store",
    ]
    if let csp { headers["Content-Security-Policy"] = csp }
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  private func fail(_ task: any WKURLSchemeTask) {
    task.didFailWithError(URLError(.fileDoesNotExist))
  }

  static func imageMime(_ data: Data) -> String {
    let bytes = [UInt8](data.prefix(4))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if bytes.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
    if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
    return "application/octet-stream"
  }
}

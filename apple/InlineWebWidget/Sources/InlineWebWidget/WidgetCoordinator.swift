#if os(macOS)
import AppKit
import WebKit

public enum WidgetRequest: Sendable, Equatable {
  case copy(String)
  case sendPrompt(String)
  case action(name: String, payloadJSON: String)
  case openLink(URL)
  case openImage(src: String, name: String)
}

public enum WidgetEvent: Sendable {
  case mountStarted(key: String, cold: Bool)
  case rendered(key: String, milliseconds: Double, cold: Bool)
  case unmounted(key: String, snapshotted: Bool)
  case heightReported(key: String, height: Int)
  case scriptError(key: String, message: String)
  case rejected(key: String, method: String, reason: String)
  case processTerminated(key: String)
}

@MainActor
public protocol WidgetCoordinatorDelegate: AnyObject {
  /// A widget's planned height changed; note the row height (no animation).
  func widgetCoordinator(_ coordinator: WidgetCoordinator, heightChangedFor key: String)
  /// A gesture-checked bridge request. Return nil to accept, or a reason to reject.
  func widgetCoordinator(_ coordinator: WidgetCoordinator, perform request: WidgetRequest, for key: String) -> String?
  func widgetCoordinator(_ coordinator: WidgetCoordinator, didEmit event: WidgetEvent)
}

/// Owns the shared web view configuration, the pool, the live budget, and the
/// height, snapshot and state caches. Rows never create web views themselves.
@MainActor
public final class WidgetCoordinator: NSObject {
  public struct Configuration: Sendable {
    public var originMode: WidgetOriginMode = .perWidget
    public var maxLive = 3
    public var poolSize = 3
    public var inlineHeightCap = 720
    public var gestureWindow: TimeInterval = 10
    public var actionsPerMinute = 10
    public init() {}
  }

  private struct LiveEntry {
    var webView: WidgetWebView
    weak var host: WidgetHostView?
    var content: WidgetContent
    var startedAt: CFAbsoluteTime
    var cold: Bool
    var rendered = false
    var actionTimes: [Date] = []
  }

  public weak var delegate: WidgetCoordinatorDelegate?
  public let configuration: Configuration
  public let schemeHandler = WidgetSchemeHandler()
  public private(set) var theme: WidgetTheme

  private lazy var webViewConfiguration: WKWebViewConfiguration = makeWebViewConfiguration()
  private var idle: [WidgetWebView] = []
  private var live: [String: LiveEntry] = [:]
  private var lruKeys: [String] = []
  private var heights: [String: Int] = [:]
  private let snapshots = NSCache<NSString, NSImage>()
  private var states: [String: String] = [:]
  public private(set) var webViewsCreated = 0

  public init(configuration: Configuration = Configuration(), theme: WidgetTheme) {
    self.configuration = configuration
    self.theme = theme
    super.init()
    snapshots.countLimit = 200
    // Decoded snapshots are large; a disk cache of compressed images backs this in the app.
    snapshots.totalCostLimit = 64 * 1024 * 1024
  }

  // MARK: First-frame data (no WebKit)

  static func widthBucket(_ width: CGFloat) -> Int { Int(width / 16) }

  /// Content height for a row of the given width: measured, then the sender's hint, then 240.
  public func plannedHeight(for content: WidgetContent, width: CGFloat) -> Int {
    let measured = heights["\(content.key)|\(Self.widthBucket(width))"]
    let raw = measured ?? content.heightHint ?? 240
    return min(configuration.inlineHeightCap, WidgetDocument.clampHeight(raw))
  }

  public func measuredHeight(for content: WidgetContent, width: CGFloat) -> Int? {
    heights["\(content.key)|\(Self.widthBucket(width))"]
  }

  public func snapshot(for content: WidgetContent, width: CGFloat) -> NSImage? {
    snapshots.object(forKey: snapshotKey(content.key, width: width) as NSString)
  }

  private func snapshotKey(_ key: String, width: CGFloat) -> String {
    "\(key)|\(theme.cacheKey)|\(Self.widthBucket(width))"
  }

  public func isLive(_ key: String) -> Bool { live[key] != nil }
  public var liveKeys: [String] { lruKeys }
  public var idleCount: Int { idle.count }

  public func liveWebView(for key: String) -> WidgetWebView? { live[key]?.webView }
  public var allWebViews: [WidgetWebView] { live.values.map(\.webView) + idle }

  // MARK: Mounting

  /// Mounts a live web view into a visible, settled row. Evicts the least
  /// recently used widget that is not in `keep` when over budget.
  public func mount(_ host: WidgetHostView, keep: Set<String> = []) {
    guard let content = host.content else { return }
    if live[content.key] != nil {
      touch(content.key)
      return
    }
    while live.count >= configuration.maxLive {
      guard let victim = lruKeys.first(where: { !keep.contains($0) }) else { return }
      unmount(key: victim)
    }
    let cold = idle.isEmpty
    let webView = idle.popLast() ?? makeWebView()
    webView.widgetKey = content.key
    webView.resetInteraction()
    let width = host.contentWidth
    let document = WidgetDocument.build(
      content: content,
      theme: theme,
      state: states[content.key],
      context: context(width: width, expanded: false)
    )
    schemeHandler.register(content: content, document: document, mode: configuration.originMode)
    live[content.key] = LiveEntry(webView: webView, host: host, content: content, startedAt: CFAbsoluteTimeGetCurrent(), cold: cold)
    touch(content.key)
    host.attach(webView)
    delegate?.widgetCoordinator(self, didEmit: .mountStarted(key: content.key, cold: cold))
    webView.load(URLRequest(url: WidgetURL.documentURL(for: content.key, mode: configuration.originMode)))
  }

  /// Moves a live widget's web view into a new host without reloading it, as when
  /// a row is rebuilt after a height change. Returns false when the key isn't live.
  @discardableResult
  public func rehost(_ host: WidgetHostView) -> Bool {
    guard let content = host.content, var entry = live[content.key] else { return false }
    if entry.host === host { return true }
    if let previous = entry.host, previous.content?.key == content.key { previous.detach(showing: nil) }
    entry.host = host
    live[content.key] = entry
    touch(content.key)
    host.attach(entry.webView)
    if entry.rendered { host.showLive() }
    return true
  }

  /// Whether this host currently shows the live web view for its widget.
  public func isHosting(_ host: WidgetHostView) -> Bool {
    guard let key = host.content?.key else { return false }
    return live[key]?.host === host
  }

  /// Starts one pooled web view, so the first widget skips WebContent process launch.
  public func prewarm() {
    guard idle.isEmpty, live.isEmpty else { return }
    let webView = makeWebView()
    webView.loadHTMLString("", baseURL: nil)
    idle.append(webView)
  }

  /// Snapshots (when rendered) and returns the web view to the pool.
  public func unmount(key: String, snapshot: Bool = true, completion: (@MainActor () -> Void)? = nil) {
    guard let entry = live.removeValue(forKey: key) else {
      completion?()
      return
    }
    lruKeys.removeAll { $0 == key }
    let finish: @MainActor (NSImage?) -> Void = { [weak self] image in
      guard let self else { return }
      if let image, let host = entry.host {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        self.snapshots.setObject(image, forKey: self.snapshotKey(key, width: host.contentWidth) as NSString, cost: pixels * 4)
      }
      if let host = entry.host, host.content?.key == key {
        host.detach(showing: image)
      } else {
        entry.webView.removeFromSuperview()
      }
      self.recycle(entry.webView)
      self.schemeHandler.unregister(key: key, mode: self.configuration.originMode)
      self.delegate?.widgetCoordinator(self, didEmit: .unmounted(key: key, snapshotted: image != nil))
      completion?()
    }
    guard snapshot, entry.rendered, entry.webView.window != nil else { return finish(nil) }
    let config = WKSnapshotConfiguration()
    config.afterScreenUpdates = false
    // Only what the row shows: a 1,900pt page capped at 720pt would otherwise cost ~4x the pixels.
    let visibleHeight = min(entry.webView.bounds.height, entry.host?.visibleContentHeight ?? entry.webView.bounds.height)
    config.rect = NSRect(x: 0, y: 0, width: entry.webView.bounds.width, height: visibleHeight)
    entry.webView.takeSnapshot(with: config) { image, _ in
      MainActor.assumeIsolated { finish(image) }
    }
  }

  public func unmountAll() {
    for key in lruKeys { unmount(key: key, snapshot: false) }
  }

  private func touch(_ key: String) {
    lruKeys.removeAll { $0 == key }
    lruKeys.append(key)
  }

  private func recycle(_ webView: WidgetWebView) {
    webView.widgetKey = nil
    webView.removeFromSuperview()
    if idle.count < configuration.poolSize {
      // Releases the previous page's JS heap and DOM while pooled.
      webView.loadHTMLString("", baseURL: nil)
      idle.append(webView)
    }
  }

  public func setTheme(_ theme: WidgetTheme) {
    guard theme != self.theme else { return }
    self.theme = theme
    snapshots.removeAllObjects()
    for (_, entry) in live {
      send(to: entry.webView, message: [
        "jsonrpc": "2.0",
        "method": "ui/notifications/host-context-changed",
        "params": ["theme": theme.appearance.rawValue, "styles": ["variables": theme.variables]],
      ])
    }
  }

  private func context(width: CGFloat, expanded: Bool) -> [String: String] {
    [
      "appearance": theme.appearance.rawValue,
      "platform": "macos",
      "width": String(Int(width)),
      "locale": Locale.current.identifier,
      "isExpanded": expanded ? "true" : "false",
    ]
  }

  // MARK: Web view setup

  private func makeWebViewConfiguration() -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(schemeHandler, forURLScheme: WidgetURL.scheme)
    config.userContentController.add(WeakScriptHandler(self), contentWorld: .page, name: WidgetRuntime.messageHandlerName)
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.preferences.isElementFullscreenEnabled = false
    config.mediaTypesRequiringUserActionForPlayback = .all
    config.suppressesIncrementalRendering = false
    return config
  }

  private func makeWebView() -> WidgetWebView {
    webViewsCreated += 1
    let webView = WidgetWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 240), configuration: webViewConfiguration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsLinkPreview = false
    webView.allowsMagnification = false
    webView.allowsBackForwardNavigationGestures = false
    webView.setValue(false, forKey: "drawsBackground")
    #if DEBUG
    webView.isInspectable = true
    #endif
    return webView
  }

  // MARK: Bridge

  fileprivate func handle(_ message: WKScriptMessage) {
    guard let webView = message.webView as? WidgetWebView, let key = webView.widgetKey, var entry = live[key] else { return }
    guard let body = message.body as? [String: Any], let method = body["method"] as? String else { return }
    let id = body["id"]
    let params = body["params"] as? [String: Any] ?? [:]

    // Only the widget's own main frame, on its own origin and document.
    let expected = WidgetURL.documentURL(for: key, mode: configuration.originMode)
    let origin = message.frameInfo.securityOrigin
    guard message.frameInfo.isMainFrame,
          origin.protocol == WidgetURL.scheme,
          origin.host == expected.host,
          message.frameInfo.request.url?.path == expected.path
    else {
      return reject(webView, key: key, id: id, method: method, reason: "Untrusted frame")
    }

    switch method {
    case "ui/notifications/size-changed":
      if let height = (params["height"] as? NSNumber)?.intValue, height > 0, let host = entry.host {
        recordHeight(height, for: entry.content, host: host)
      }
    case "inline/notifications/rendered":
      if !entry.rendered {
        entry.rendered = true
        live[key] = entry
        let ms = (CFAbsoluteTimeGetCurrent() - entry.startedAt) * 1000
        entry.host?.showLive()
        delegate?.widgetCoordinator(self, didEmit: .rendered(key: key, milliseconds: ms, cold: entry.cold))
      }
      if let height = (params["height"] as? NSNumber)?.intValue, height > 0, let host = entry.host {
        recordHeight(height, for: entry.content, host: host)
      }
    case "inline/notifications/error":
      delegate?.widgetCoordinator(self, didEmit: .scriptError(key: key, message: params["message"] as? String ?? ""))
    case "inline/state":
      let value = params["state"] ?? NSNull()
      if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), data.count <= 16 * 1024 {
        states[key] = String(decoding: data, as: UTF8.self)
      } else {
        delegate?.widgetCoordinator(self, didEmit: .rejected(key: key, method: method, reason: "State over 16 KiB"))
      }
    case "inline/copy", "ui/message", "inline/action", "ui/open-link", "inline/open-image":
      guard let request = Self.request(method: method, params: params) else {
        return reject(webView, key: key, id: id, method: method, reason: "Invalid parameters")
      }
      guard let touched = webView.lastUserInteraction, Date().timeIntervalSince(touched) <= configuration.gestureWindow else {
        return reject(webView, key: key, id: id, method: method, reason: "Needs a user gesture")
      }
      let now = Date()
      entry.actionTimes = entry.actionTimes.filter { now.timeIntervalSince($0) < 60 }
      guard entry.actionTimes.count < configuration.actionsPerMinute else {
        return reject(webView, key: key, id: id, method: method, reason: "Too many requests")
      }
      entry.actionTimes.append(now)
      live[key] = entry
      if let reason = delegate?.widgetCoordinator(self, perform: request, for: key) {
        return reject(webView, key: key, id: id, method: method, reason: reason)
      }
      if let id { send(to: webView, message: ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]) }
    default:
      reject(webView, key: key, id: id, method: method, reason: "Unknown method")
    }
  }

  static func request(method: String, params: [String: Any]) -> WidgetRequest? {
    switch method {
    case "inline/copy":
      guard let text = params["text"] as? String, text.utf8.count <= 64 * 1024 else { return nil }
      return .copy(text)
    case "ui/message":
      guard let text = params["text"] as? String, !text.isEmpty, text.utf8.count <= 4 * 1024 else { return nil }
      return .sendPrompt(text)
    case "inline/action":
      guard let name = params["name"] as? String, !name.isEmpty, name.count <= 64 else { return nil }
      let payload = params["payload"] ?? NSNull()
      guard let data = try? JSONSerialization.data(withJSONObject: ["name": name, "payload": payload]), data.count <= 4 * 1024 else { return nil }
      return .action(name: name, payloadJSON: String(decoding: data, as: UTF8.self))
    case "ui/open-link":
      guard let string = params["url"] as? String, let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else { return nil }
      return .openLink(url)
    case "inline/open-image":
      guard let src = params["src"] as? String, src.count <= 2_000_000 else { return nil }
      return .openImage(src: src, name: params["name"] as? String ?? "")
    default:
      return nil
    }
  }

  private func recordHeight(_ height: Int, for content: WidgetContent, host: WidgetHostView) {
    let width = host.contentWidth
    let before = plannedHeight(for: content, width: width)
    heights["\(content.key)|\(Self.widthBucket(width))"] = height
    delegate?.widgetCoordinator(self, didEmit: .heightReported(key: content.key, height: height))
    if plannedHeight(for: content, width: width) != before {
      delegate?.widgetCoordinator(self, heightChangedFor: content.key)
    }
  }

  private func reject(_ webView: WidgetWebView, key: String, id: Any?, method: String, reason: String) {
    delegate?.widgetCoordinator(self, didEmit: .rejected(key: key, method: method, reason: reason))
    if let id { send(to: webView, message: ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": reason]]) }
  }

  private func send(to webView: WKWebView, message: [String: Any]) {
    webView.callAsyncJavaScript(
      "window.__inlineWidgetReceive && window.__inlineWidgetReceive(m)",
      arguments: ["m": message],
      in: nil,
      in: .page,
      completionHandler: nil
    )
  }
}

extension WidgetCoordinator: WKNavigationDelegate, WKUIDelegate {
  public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    let url = navigationAction.request.url
    // Only host-initiated loads: the widget document and the blank page used while pooled.
    if let url, let key = (webView as? WidgetWebView)?.widgetKey,
       url == WidgetURL.documentURL(for: key, mode: configuration.originMode),
       navigationAction.navigationType == .other {
      return decisionHandler(.allow)
    }
    if url?.absoluteString == "about:blank" { return decisionHandler(.allow) }
    decisionHandler(.cancel)
  }

  public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    nil
  }

  public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
    decisionHandler(.deny)
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard let key = (webView as? WidgetWebView)?.widgetKey else { return }
    delegate?.widgetCoordinator(self, didEmit: .processTerminated(key: key))
    unmount(key: key, snapshot: false)
  }
}

/// Breaks the retain cycle between the content controller and the coordinator.
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
  weak var coordinator: WidgetCoordinator?
  init(_ coordinator: WidgetCoordinator) { self.coordinator = coordinator }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    coordinator?.handle(message)
  }
}
#endif

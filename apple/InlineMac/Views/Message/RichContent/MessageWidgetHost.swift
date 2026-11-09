import AppKit
import InlineKit
import InlineProtocol
import InlineWebWidget
import Logger

/// Measured widget heights, readable from layout on any thread. Keys are a
/// message revision's widget key, so an edit starts from the sender's hint again.
final class MessageWidgetHeights: @unchecked Sendable {
  static let shared = MessageWidgetHeights()

  private let lock = NSLock()
  private var heights: [String: Int] = [:]
  private var recency: [String] = []
  private let capacity = 512

  private init() {}

  /// Planner input for a message, or nil while widgets are off (flat fallback).
  func layout(for message: InlineKit.Message) -> RichBlockWidgetLayout? {
    guard AppSettings.shared.messageWidgetsEnabled, let payload = message.blockContentPayload else { return nil }
    let key = MessageWidgetKey.make(message: message, payload: payload)
    lock.lock()
    defer { lock.unlock() }
    guard let height = heights[key], let widgetID = MessageWidgetKey.firstWidget(in: payload.content.blocks)?.widgetID
    else { return RichBlockWidgetLayout(measuredHeights: [:]) }
    return RichBlockWidgetLayout(measuredHeights: [widgetID: height])
  }

  func height(forKey key: String) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return heights[key]
  }

  /// Returns true when the stored height changed.
  func record(_ height: Int, forKey key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard heights[key] != height else { return false }
    heights[key] = height
    recency.removeAll { $0 == key }
    recency.append(key)
    while recency.count > capacity { heights[recency.removeFirst()] = nil }
    return true
  }
}

enum MessageWidgetKey {
  /// One widget per message, so the message and its revision identify it. The
  /// key also names the widget's origin, so it stays DNS-safe.
  static func make(message: InlineKit.Message, payload: BlockContentPayload) -> String {
    "m\(message.stableId)r\(String(UInt(bitPattern: payload.cacheSignature), radix: 36))"
  }

  static func firstWidget(in blocks: [InlineProtocol.Block]) -> InlineProtocol.BlockWidget? {
    for block in blocks {
      switch block.kind {
      case let .widget(widget): return widget
      case let .disclosure(disclosure): if let found = firstWidget(in: disclosure.children) { return found }
      case let .quote(quote): if let found = firstWidget(in: quote.children) { return found }
      case let .callout(callout): if let found = firstWidget(in: callout.children) { return found }
      case let .list(list):
        for item in list.items { if let found = firstWidget(in: item.children) { return found } }
      default: break
      }
    }
    return nil
  }

  /// Follows a planner path: `.block(i)` steps into a block, `.listItem(i)` into a list item.
  static func widget(at path: BlockContentPath, in content: InlineProtocol.BlockContent) -> InlineProtocol.BlockWidget? {
    var blocks = content.blocks
    var current: InlineProtocol.Block?
    for component in path.components {
      switch component {
      case let .block(index):
        if let parent = current {
          switch parent.kind {
          case let .disclosure(value): blocks = value.children
          case let .quote(value): blocks = value.children
          case let .callout(value): blocks = value.children
          default: break
          }
        }
        guard blocks.indices.contains(index) else { return nil }
        current = blocks[index]
      case let .listItem(index):
        guard case let .list(list)? = current?.kind, list.items.indices.contains(index) else { return nil }
        blocks = list.items[index].children
        current = nil
      case .albumImage:
        return nil
      }
    }
    guard case let .widget(widget)? = current?.kind else { return nil }
    return widget
  }
}

/// The app's one widget coordinator: mounts live web views into settled,
/// visible rows within the live budget, feeds measured heights back into
/// layout, and carries out bridge requests.
@MainActor
final class MessageWidgetHost: NSObject, WidgetCoordinatorDelegate {
  static let shared = MessageWidgetHost()

  private struct Registration {
    weak var view: RichBlockWidgetNodeView?
    var message: InlineKit.Message
  }

  private let log = Log.scoped("MessageWidgets")
  private var registrations: [String: Registration] = [:]
  private var isLiveScrolling = false
  private var evaluation: DispatchWorkItem?
  private var appearanceObservation: NSKeyValueObservation?

  private(set) lazy var coordinator: WidgetCoordinator = {
    let coordinator = WidgetCoordinator(theme: WidgetTheme.current(for: NSApp.effectiveAppearance))
    coordinator.delegate = self
    appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
      MainActor.assumeIsolated {
        MessageWidgetHost.shared.coordinator.setTheme(WidgetTheme.current(for: NSApp.effectiveAppearance))
      }
    }
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: nil)
    center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: nil)
    center.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: nil)
    return coordinator
  }()

  // MARK: Rows

  func register(_ view: RichBlockWidgetNodeView, key: String, message: InlineKit.Message) {
    registrations[key] = Registration(view: view, message: message)
    coordinator.prewarm()
    if coordinator.isLive(key) { coordinator.rehost(view.host) }
    scheduleEvaluation()
  }

  func unregister(_ view: RichBlockWidgetNodeView, key: String) {
    guard registrations[key]?.view === view else { return }
    registrations[key] = nil
    if coordinator.isHosting(view.host) { coordinator.unmount(key: key) }
  }

  // MARK: Mounting

  @objc private func liveScrollStarted() { isLiveScrolling = true }

  @objc private func liveScrollEnded() {
    isLiveScrolling = false
    scheduleEvaluation()
  }

  @objc private func viewportChanged() {
    guard !registrations.isEmpty else { return }
    scheduleEvaluation()
  }

  private func scheduleEvaluation() {
    evaluation?.cancel()
    let item = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.evaluate() }
    }
    evaluation = item
    // Mount only once scrolling has settled for 150ms.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
  }

  private func evaluate() {
    guard !isLiveScrolling else { return }
    var visible: [(key: String, host: WidgetHostView, shown: CGFloat)] = []
    for (key, registration) in registrations {
      guard let view = registration.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
      let host = view.host
      let shown = host.visibleRect.height
      guard host.bounds.height > 0, shown >= min(host.bounds.height, 200) * 0.5 else { continue }
      visible.append((key, host, shown))
    }
    let visibleKeys = Set(visible.map(\.key))
    for key in coordinator.liveKeys where !visibleKeys.contains(key) {
      coordinator.unmount(key: key)
    }
    let ranked = visible.sorted { $0.shown > $1.shown }.prefix(coordinator.configuration.maxLive)
    let keep = Set(ranked.map(\.key))
    for entry in ranked {
      if coordinator.isLive(entry.key) {
        coordinator.rehost(entry.host)
      } else {
        coordinator.mount(entry.host, keep: keep)
      }
    }
  }

  // MARK: WidgetCoordinatorDelegate

  func widgetCoordinator(_ coordinator: WidgetCoordinator, heightChangedFor key: String) {}

  func widgetCoordinator(_ coordinator: WidgetCoordinator, didEmit event: WidgetEvent) {
    switch event {
    case let .heightReported(key, height):
      guard MessageWidgetHeights.shared.record(height, forKey: key),
            let message = registrations[key]?.message
      else { return }
      NotificationCenter.default.post(
        name: .richBlockLayoutStateDidChange,
        object: self,
        userInfo: ["messageStableID": message.stableId]
      )
    case let .rejected(key, method, reason):
      log.debug("Widget \(key) request \(method) rejected: \(reason)")
    case let .scriptError(key, message):
      log.debug("Widget \(key) script error: \(message)")
    case let .processTerminated(key):
      log.warning("Widget \(key) web content process terminated")
    case .mountStarted, .rendered, .unmounted:
      break
    }
  }

  func widgetCoordinator(_ coordinator: WidgetCoordinator, perform request: WidgetRequest, for key: String) -> String? {
    guard let message = registrations[key]?.message else { return "Widget is not visible" }
    switch request {
    case let .copy(text):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    case let .openLink(url):
      NSWorkspace.shared.open(url)
    case let .sendPrompt(text):
      // The composer shows what will be posted under the viewer's name; nothing is sent here.
      ChatsManager.get(for: message.peerId, chatId: message.chatId)
        .prefillPrompt(text, replyingTo: message.messageId)
    case let .action(name, payloadJSON):
      guard let widget = message.blockContentPayload.flatMap({ MessageWidgetKey.firstWidget(in: $0.content.blocks) }) else {
        return "Widget is gone"
      }
      invoke(message: message, widgetID: widget.widgetID, name: name, payloadJSON: payloadJSON)
    case .openImage:
      return "Images are not supported yet"
    }
    return nil
  }

  private func invoke(message: InlineKit.Message, widgetID: String, name: String, payloadJSON: String) {
    // The bridge wraps calls as {"name", "payload"}; the server wants the payload alone.
    let payload: Data? = (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any])
      .flatMap { $0["payload"] }
      .flatMap { $0 is NSNull ? nil : try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
    let peer = message.peerId.toInputPeer()
    let messageID = message.messageId
    let log = log
    Task {
      do {
        _ = try await Api.realtime.callRpcDirect(
          method: .invokeMessageAction,
          input: .invokeMessageAction(.with {
            $0.peerID = peer
            $0.messageID = messageID
            $0.actionID = widgetID
            $0.widgetCall = .with {
              $0.name = name
              if let payload { $0.payload = payload }
            }
          })
        )
      } catch {
        log.error("Widget action failed", error: error)
      }
    }
  }
}

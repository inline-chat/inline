import AppKit
import InlineKit
import InlineWebWidget

/// A bot's HTML widget inside a message. Configuring the row only uses
/// first-frame data (snapshot, measured height); the host mounts a live web
/// view once the row is visible and scrolling has settled.
final class RichBlockWidgetNodeView: RichBlockRenderableView {
  let host = WidgetHostView(frame: .zero)
  private var key: String?
  private var message: Message?

  init() {
    super.init(reuseKind: .widget)
    host.showsOpenButton = false
    addSubview(host)
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .widget(widgetNode) = node.kind,
          let payload = context.relatedMessage.blockContentPayload,
          let widget = MessageWidgetKey.widget(at: node.path, in: payload.content)
    else { return release() }
    let message = context.relatedMessage
    let key = MessageWidgetKey.make(message: message, payload: payload)
    if self.key != key { release() }
    self.key = key
    self.message = message

    let source = context.attributedText.string as NSString
    let titleRange = NSRange(location: widgetNode.title.offset, length: widgetNode.title.length)
    let title = NSMaxRange(titleRange) <= source.length ? source.substring(with: titleRange) : ""
    let content = WidgetContent(
      key: key,
      title: title,
      html: widget.html,
      heightHint: widget.hasHeight ? Int(widget.height) : nil
    )
    let coordinator = MessageWidgetHost.shared.coordinator
    // The page lays out at its measured height; the row clips it at the inline cap.
    let pageHeight = MessageWidgetHeights.shared.height(forKey: key).map { CGFloat($0) } ?? widgetNode.contentHeight
    host.configure(
      content: content,
      snapshot: coordinator.snapshot(for: content, width: node.frame.width),
      contentHeight: max(pageHeight, widgetNode.contentHeight),
      isClipped: widgetNode.isClipped
    )
    MessageWidgetHost.shared.register(self, key: key, message: message)
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .widget(widgetNode) = node.kind else { return }
    host.isClipped = widgetNode.isClipped
  }

  override func layout() {
    super.layout()
    host.frame = bounds
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    // Leaving the window: snapshot while the page can still draw.
    if newWindow == nil { release() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Back in a window without a fresh apply: register the same widget again.
    if window != nil, key == nil, let content = host.content, let message {
      key = content.key
      MessageWidgetHost.shared.register(self, key: content.key, message: message)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    release()
    message = nil
  }

  private func release() {
    guard let key else { return }
    MessageWidgetHost.shared.unregister(self, key: key)
    self.key = nil
  }
}

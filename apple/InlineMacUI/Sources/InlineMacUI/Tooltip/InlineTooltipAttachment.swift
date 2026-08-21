import AppKit
import ObjectiveC
import SwiftUI

private nonisolated(unsafe) var inlineTooltipAttachmentKey: UInt8 = 0

@MainActor
private final class InlineTooltipAttachment: NSResponder {
  private weak var view: NSView?
  private var trackingArea: NSTrackingArea?
  private var windowObservation: NSKeyValueObservation?
  private var content: InlineTooltipContent
  private var placement: InlineTooltipPlacement
  private var isHovered = false

  init(
    view: NSView,
    content: InlineTooltipContent,
    placement: InlineTooltipPlacement
  ) {
    self.view = view
    self.content = content
    self.placement = placement
    super.init()
    installTrackingArea()
    windowObservation = view.observe(\.window, options: [.new]) { [weak self, weak view] _, _ in
      MainActor.assumeIsolated {
        guard view?.window == nil else { return }
        self?.targetLeftWindow()
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(content: InlineTooltipContent, placement: InlineTooltipPlacement) {
    self.content = content
    self.placement = placement
    if isHovered {
      show()
    }
  }

  func show() {
    guard let view else { return }
    isHovered = true
    InlineTooltipManager.shared.show(content, anchoredTo: view, placement: placement)
  }

  func hide() {
    guard let view else { return }
    isHovered = false
    InlineTooltipManager.shared.hide(anchoredTo: view)
  }

  func detach() {
    guard let view else { return }
    if let trackingArea {
      view.removeTrackingArea(trackingArea)
      self.trackingArea = nil
    }
    windowObservation?.invalidate()
    windowObservation = nil
    isHovered = false
    InlineTooltipManager.shared.targetWasRemoved(view)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    show()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard !mouseIsInsideView else { return }
    hide()
  }

  private func targetLeftWindow() {
    guard let view else { return }
    isHovered = false
    InlineTooltipManager.shared.targetWasRemoved(view)
  }

  private func installTrackingArea() {
    guard let view else { return }
    if let trackingArea {
      view.removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    view.addTrackingArea(area)
    trackingArea = area
  }

  private var mouseIsInsideView: Bool {
    guard let view, let window = view.window else { return false }
    let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return view.bounds.contains(point)
  }
}

public extension NSView {
  func setInlineTooltip(
    _ content: InlineTooltipContent,
    placement: InlineTooltipPlacement = .automatic
  ) {
    toolTip = nil
    if let attachment = inlineTooltipAttachment {
      attachment.update(content: content, placement: placement)
    } else {
      inlineTooltipAttachment = InlineTooltipAttachment(
        view: self,
        content: content,
        placement: placement
      )
    }
  }

  func setInlineTooltip(
    _ text: LocalizedStringResource,
    shortcut: InlineTooltipShortcut? = nil,
    placement: InlineTooltipPlacement = .automatic
  ) {
    setInlineTooltip(InlineTooltipContent(text, shortcut: shortcut), placement: placement)
  }

  func setInlineTooltip(
    verbatim text: String,
    shortcut: InlineTooltipShortcut? = nil,
    placement: InlineTooltipPlacement = .automatic
  ) {
    setInlineTooltip(InlineTooltipContent(verbatim: text, shortcut: shortcut), placement: placement)
  }

  func showInlineTooltip() {
    inlineTooltipAttachment?.show()
  }

  func hideInlineTooltip() {
    inlineTooltipAttachment?.hide()
  }

  func removeInlineTooltip() {
    inlineTooltipAttachment?.detach()
    inlineTooltipAttachment = nil
  }

  private var inlineTooltipAttachment: InlineTooltipAttachment? {
    get {
      objc_getAssociatedObject(self, &inlineTooltipAttachmentKey) as? InlineTooltipAttachment
    }
    set {
      objc_setAssociatedObject(
        self,
        &inlineTooltipAttachmentKey,
        newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
    }
  }
}

public extension View {
  func inlineTooltip(
    _ text: LocalizedStringResource,
    shortcut: InlineTooltipShortcut? = nil,
    placement: InlineTooltipPlacement = .automatic
  ) -> some View {
    modifier(InlineTooltipModifier(
      tooltip: InlineTooltipContent(text, shortcut: shortcut),
      placement: placement
    ))
  }

  func inlineTooltip(
    verbatim text: String,
    shortcut: InlineTooltipShortcut? = nil,
    placement: InlineTooltipPlacement = .automatic
  ) -> some View {
    modifier(InlineTooltipModifier(
      tooltip: InlineTooltipContent(verbatim: text, shortcut: shortcut),
      placement: placement
    ))
  }
}

private struct InlineTooltipModifier: ViewModifier {
  let tooltip: InlineTooltipContent
  let placement: InlineTooltipPlacement

  func body(content: Content) -> some View {
    content.background {
      InlineTooltipAnchorRepresentable(tooltip: tooltip, placement: placement)
        .accessibilityHidden(true)
    }
  }
}

private struct InlineTooltipAnchorRepresentable: NSViewRepresentable {
  let tooltip: InlineTooltipContent
  let placement: InlineTooltipPlacement

  func makeNSView(context: Context) -> InlineTooltipAnchorView {
    let view = InlineTooltipAnchorView()
    update(view)
    return view
  }

  func updateNSView(_ nsView: InlineTooltipAnchorView, context: Context) {
    update(nsView)
  }

  static func dismantleNSView(_ nsView: InlineTooltipAnchorView, coordinator: Void) {
    nsView.removeInlineTooltip()
  }

  private func update(_ view: InlineTooltipAnchorView) {
    view.setInlineTooltip(tooltip, placement: placement)
  }
}

@MainActor
final class InlineTooltipAnchorView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

import AppKit
import Foundation
import InlineKit
import Logger

/// The attachments under a message, top to bottom at the plan's sizes and spacing, leading-aligned. Laid out by
/// frame (it was a stack view: its items' constraints pulled message rows into the window's layout engine).
class MessageAttachmentsView: NSView {

  // MARK: - Properties

  /// Message
  private var message: Message
  private var usesOutgoingBubbleStyle: Bool

  /// Renderable attachments (order preserved)
  var attachments: [FullAttachment]

  /// Track attachment views by id
  var attachmentViews: [Int64: AttachmentView] = [:]
  /// The item views in order, and their sizes from the plan.
  private(set) var arrangedSubviews: [NSView] = []
  private var itemSizes: [Int64: NSSize] = [:]

  // MARK: - Lifecycle

  init(
    attachments: [FullAttachment],
    message: Message,
    usesOutgoingBubbleStyle: Bool,
    itemPlans: [MessageSizeCalculator.LayoutPlan] = []
  ) {
    self.message = message
    self.usesOutgoingBubbleStyle = usesOutgoingBubbleStyle
    // Initialize attachments as empty array, we'll add attachments later in configure()
    self.attachments = []
    super.init(frame: .zero)

    // Setup
    setup()

    // Initial configuration
    configure(attachments: attachments)
    apply(itemPlans: itemPlans)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Internals

  private var log = Log.scoped("MessageAttachmentsView", enableTracing: false)

  // MARK: - Methods

  private func setup() {
    // Placed by frame (message rows' `layoutParts`).
    translatesAutoresizingMaskIntoConstraints = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { needsLayout = true }
  }

  override func layout() {
    super.layout()
    layoutItems()
  }

  /// Items top to bottom, `Theme.messageAttachmentsSpacing` apart, at the leading edge.
  private func layoutItems() {
    let size = bounds.size
    let mirrored = userInterfaceLayoutDirection == .rightToLeft
    var top: CGFloat = 0
    for (index, attachment) in attachments.enumerated() {
      guard let view = attachmentViews[attachment.id] else { continue }
      if index > 0 { top += Theme.messageAttachmentsSpacing }
      let itemSize = itemSizes[attachment.id] ?? view.frame.size
      let rect = NSRect(
        x: mirrored ? size.width - itemSize.width : 0,
        y: isFlipped ? top : size.height - top - itemSize.height,
        width: itemSize.width,
        height: itemSize.height
      )
      let frame = backingAlignedRect(rect, options: .alignAllEdgesNearest)
      if view.frame != frame { view.frame = frame }
      top += itemSize.height
    }
  }

  func configure(
    attachments: [FullAttachment],
    message: Message? = nil,
    usesOutgoingBubbleStyle nextStyle: Bool? = nil
  ) {
    log.trace("Configuring attachments: \(attachments)")

    let nextMessage = message ?? self.message
    let messageChanged = nextMessage != self.message
    let nextStyle = nextStyle ?? usesOutgoingBubbleStyle
    let styleChanged = nextStyle != usesOutgoingBubbleStyle
    self.message = nextMessage
    usesOutgoingBubbleStyle = nextStyle

    let renderableAttachments = attachments.filter(\.isRenderableAttachment)

    // Short‑circuit if nothing changed
    guard renderableAttachments != self.attachments || styleChanged else {
      if messageChanged {
        updateURLPreviewViews(with: renderableAttachments, message: nextMessage)
      }
      return
    }

    if !styleChanged, updateExistingViews(with: renderableAttachments, message: nextMessage) {
      self.attachments = renderableAttachments
      return
    }

    // Reset and rebuild in message order to keep UI deterministic
    attachmentsViewCleanup()
    self.attachments = renderableAttachments

    for attachment in renderableAttachments {
      log.trace("Adding attachment: \(attachment)")
      addAttachment(attachment)
    }
  }

  /// Add attachment to the view.
  private func addAttachment(_ attachment: FullAttachment) {
    let attachmentView: AttachmentView

    if let _ = attachment.externalTask {
      attachmentView = ExternalTaskAttachmentView(
        fullAttachment: attachment,
        message: message,
        usesOutgoingBubbleStyle: usesOutgoingBubbleStyle
      )
    } else if attachment.urlPreview != nil {
      attachmentView = URLPreviewAttachmentView(
        fullAttachment: attachment,
        message: message,
        usesOutgoingBubbleStyle: usesOutgoingBubbleStyle
      )
    } else {
      // Unsupported attachment type
      return
    }

    attachmentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(attachmentView)
    arrangedSubviews.append(attachmentView)
    attachmentViews[attachment.id] = attachmentView
    needsLayout = true
  }

  func apply(itemPlans: [MessageSizeCalculator.LayoutPlan]) {
    for (index, attachment) in attachments.enumerated() {
      guard index < itemPlans.count,
            let view = attachmentViews[attachment.id]
      else {
        continue
      }

      let itemPlan = itemPlans[index]
      apply(size: itemPlan.size, to: view, id: attachment.id)

      if let urlPreviewView = view as? URLPreviewAttachmentView,
         let urlPreviewPlan = itemPlan.urlPreview
      {
        urlPreviewView.apply(layout: urlPreviewPlan)
      }
    }
  }

  func interactiveHitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, bounds.contains(point) else { return nil }

    for view in arrangedSubviews.reversed() where !view.isHidden {
      let pointInView = view.convert(point, from: self)
      guard view.bounds.contains(pointInView) else { continue }
      return view.hitTest(pointInView) ?? view
    }

    return nil
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    interactiveHitTest(point)
  }

  private func apply(size: NSSize, to _: AttachmentView, id: Int64) {
    guard itemSizes[id] != size else { return }
    itemSizes[id] = size
    needsLayout = true
  }

  private func updateExistingViews(with next: [FullAttachment], message: Message) -> Bool {
    guard next.count == attachments.count else { return false }

    for (index, attachment) in next.enumerated() {
      let previous = attachments[index]
      guard previous.id == attachment.id,
            let view = attachmentViews[attachment.id]
      else {
        return false
      }

      if let urlPreviewView = view as? URLPreviewAttachmentView {
        guard urlPreviewView.canUpdate(with: attachment) else { return false }
        continue
      }

      guard previous == attachment else { return false }
    }

    updateURLPreviewViews(with: next, message: message)

    return true
  }

  private func updateURLPreviewViews(with next: [FullAttachment], message: Message) {
    for attachment in next {
      if let urlPreviewView = attachmentViews[attachment.id] as? URLPreviewAttachmentView {
        urlPreviewView.update(fullAttachment: attachment, message: message)
      }
    }
  }

  private func attachmentsViewCleanup() {
    itemSizes.removeAll()
    for view in arrangedSubviews {
      view.removeFromSuperview()
    }
    arrangedSubviews.removeAll()
    attachmentViews.removeAll()
    needsLayout = true
  }

  // MARK: - Computed
}

// MARK: - Helpers

extension FullAttachment {
  /// Any attachment type the mac client currently knows how to render inline.
  var isRenderableAttachment: Bool {
    externalTask != nil || urlPreview != nil
  }
}

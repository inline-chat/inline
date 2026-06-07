import AppKit
import Foundation
import InlineKit
import Logger

class MessageAttachmentsView: NSStackView {
  private struct ItemConstraints {
    var width: NSLayoutConstraint
    var height: NSLayoutConstraint
  }

  // MARK: - Properties

  /// Message
  private var message: Message
  private var usesOutgoingBubbleStyle: Bool

  /// Renderable attachments (order preserved)
  var attachments: [FullAttachment]

  /// Track attachment views by id
  var attachmentViews: [Int64: AttachmentView] = [:]
  private var itemConstraints: [Int64: ItemConstraints] = [:]

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
    orientation = .vertical
    translatesAutoresizingMaskIntoConstraints = false
    spacing = Theme.messageAttachmentsSpacing
    edgeInsets = .zero
    alignment = .leading
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

    addArrangedSubview(attachmentView)
    attachmentViews[attachment.id] = attachmentView
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

  private func apply(size: NSSize, to view: AttachmentView, id: Int64) {
    if let constraints = itemConstraints[id] {
      if constraints.width.constant != size.width {
        constraints.width.constant = size.width
      }
      if constraints.height.constant != size.height {
        constraints.height.constant = size.height
      }
      return
    }

    let width = view.widthAnchor.constraint(equalToConstant: size.width)
    let height = view.heightAnchor.constraint(equalToConstant: size.height)
    NSLayoutConstraint.activate([width, height])
    itemConstraints[id] = ItemConstraints(width: width, height: height)
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
    let constraints = itemConstraints.values.flatMap { [$0.width, $0.height] }
    NSLayoutConstraint.deactivate(constraints)
    itemConstraints.removeAll()

    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    attachmentViews.removeAll()
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

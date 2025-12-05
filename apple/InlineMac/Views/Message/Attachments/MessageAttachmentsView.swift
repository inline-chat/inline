import AppKit
import Foundation
import InlineKit
import Logger

class MessageAttachmentsView: NSStackView {
  // MARK: - Properties

  /// Message
  let message: Message

  /// Renderable attachments (order preserved)
  var attachments: [FullAttachment]

  /// Track attachment views by id
  var attachmentViews: [Int64: AttachmentView] = [:]

  // MARK: - Lifecycle

  init(attachments: [FullAttachment], message: Message) {
    self.message = message
    // Initialize attachments as empty array, we'll add attachments later in configure()
    self.attachments = []
    super.init(frame: .zero)

    // Setup
    setup()

    // Initial configuration
    configure(attachments: attachments)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Internals

  private var log = Log.scoped("MessageAttachmentsView", enableTracing: true)

  // MARK: - Methods

  private func setup() {
    orientation = .vertical
    translatesAutoresizingMaskIntoConstraints = false
    spacing = Theme.messageAttachmentsSpacing
    edgeInsets = .zero
    alignment = .leading
  }

  func configure(attachments: [FullAttachment]) {
    log.trace("Configuring attachments: \(attachments)")

    let renderableAttachments = attachments.filter(\.isRenderableAttachment)
    let renderableIds = renderableAttachments.map(\.id)
    let currentIds = self.attachments.map(\.id)

    // Short‑circuit if nothing changed
    guard renderableIds != currentIds else { return }

    // Reset and rebuild in message order to keep UI deterministic
    attachmentsViewCleanup()
    self.attachments = renderableAttachments

    for attachment in renderableAttachments {
      log.trace("Adding attachment: \(attachment)")
      addAttachment(attachment)
    }
  }

  /// Add attachment to the view
  ///
  /// TODO: Preserve order of attachments
  private func addAttachment(_ attachment: FullAttachment) {
    let attachmentView: AttachmentView

    if let _ = attachment.externalTask {
      attachmentView = ExternalTaskAttachmentView(fullAttachment: attachment, message: message)
    } else if attachment.isLoomPreview {
      attachmentView = LoomAttachmentView(fullAttachment: attachment, message: message)
    } else {
      // Unsupported attachment type
      return
    }

    addArrangedSubview(attachmentView)
    attachmentViews[attachment.id] = attachmentView
  }

  private func attachmentsViewCleanup() {
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
  /// Whether this attachment carries a Loom URL preview we can render.
  var isLoomPreview: Bool {
    guard let preview = urlPreview else { return false }

    if let siteName = preview.siteName?.lowercased(), siteName.contains("loom") {
      return true
    }

    if let host = URLComponents(string: preview.url)?.host?.lowercased(), host.contains("loom.com") {
      return true
    }

    return preview.url.lowercased().contains("loom.com")
  }

  /// Any attachment type the mac client currently knows how to render inline.
  var isRenderableAttachment: Bool {
    externalTask != nil || isLoomPreview
  }
}

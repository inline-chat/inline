import AppKit
import InlineKit
import Logger

class MessageAttachmentsView: NSStackView {
  // MARK: - Properties

  /// Message
  let message: Message

  /// Attachments
  var attachments: Set<FullAttachment>

  /// Track attachment views by id
  var attachmentViews: [Int64: AttachmentView] = [:]

  // MARK: - Lifecycle

  init(attachments: [FullAttachment], message: Message) {
    self.message = message
    // Initialize attachments as empty set, we'll add attachments later in configure()
    self.attachments = Set()
    super.init(frame: .zero)

    // Setup
    setup()

    // Initial configuration
    configure(attachments: attachments)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
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
  }

  func configure(attachments: [FullAttachment]) {
    log.trace("Configuring attachments: \(attachments)")

    // Track what changed.
    let newAttachments = Set(attachments)
    let removedAttachments = self.attachments.subtracting(newAttachments)
    let addedAttachments = newAttachments.subtracting(self.attachments)

    // Remove removed attachments
    for attachment in removedAttachments {
      log.trace("Removing attachment: \(attachment)")
      if let attachmentView = attachmentViews[attachment.id] {
        removeArrangedSubview(attachmentView)
        attachmentView.removeFromSuperview()
        attachmentViews.removeValue(forKey: attachment.id)
      }
    }

    // Add new attachments
    for attachment in addedAttachments {
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
    } else if let _ = attachment.urlPreview {
      // TODO: Loom
      return
    } else {
      // Unsupported attachment type
      return
    }

    addArrangedSubview(attachmentView)
    attachmentViews[attachment.id] = attachmentView
  }

  // MARK: - Computed
}

import AppKit
import InlineKit

@available(*, deprecated, message: "Use URLPreviewAttachmentView for all URL previews.")
final class LoomAttachmentView: NSView, AttachmentView {
  private let previewView: URLPreviewAttachmentView

  var attachment: Attachment {
    previewView.attachment
  }

  init(fullAttachment: FullAttachment, message: Message, usesOutgoingBubbleStyle: Bool) {
    previewView = URLPreviewAttachmentView(
      fullAttachment: fullAttachment,
      message: message,
      usesOutgoingBubbleStyle: usesOutgoingBubbleStyle
    )
    super.init(frame: .zero)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(previewView)

    NSLayoutConstraint.activate([
      previewView.leadingAnchor.constraint(equalTo: leadingAnchor),
      previewView.trailingAnchor.constraint(equalTo: trailingAnchor),
      previewView.topAnchor.constraint(equalTo: topAnchor),
      previewView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}

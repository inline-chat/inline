import AppKit

class ComposeAttachments: NSView {
  private weak var compose: ComposeAppKit?
  private var attachments: [NSImage: ImageAttachmentView] = [:]
  private let stackView: NSStackView

  init(frame: NSRect, compose: ComposeAppKit) {
    self.compose = compose

    stackView = NSStackView(frame: .zero)
    stackView.orientation = .horizontal
    stackView.spacing = 8
    stackView.translatesAutoresizingMaskIntoConstraints = false

    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var stackTopAnchor: NSLayoutConstraint!

  // Modify updateHeight to be public and return the height
  func getHeight() -> CGFloat {
    attachments.isEmpty ? 0 : 80 + Theme.composeVerticalPadding // 80 for image
  }

  func updateHeight() {
    stackTopAnchor.constant = getHeight() > 0 ? Theme.composeVerticalPadding : 0.0
  }

  private func setupView() {
    addSubview(stackView)
    stackTopAnchor = stackView.topAnchor.constraint(equalTo: topAnchor)

    NSLayoutConstraint.activate([
      stackTopAnchor,

      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  public func removeImageView(_ image: NSImage) {
    if let attachment = attachments[image] {
      stackView.removeArrangedSubview(attachment)
      attachment.removeFromSuperview()
      attachments.removeValue(forKey: image)
    }
    updateHeight()
  }

  public func addImageView(_ image: NSImage) {
    let attachmentView = ImageAttachmentView(image: image) { [weak self] in
      self?.compose?.removeImage(image)
    }
    attachmentView.translatesAutoresizingMaskIntoConstraints = false

    attachments[image] = attachmentView
    stackView.addArrangedSubview(attachmentView)
    updateHeight()
  }

  public func clearViews() {
    for (_, value) in attachments {
      stackView.removeArrangedSubview(value)
      value.removeFromSuperview()
    }
    attachments.removeAll()
    updateHeight()
  }
}

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

  private var heightConstraint: NSLayoutConstraint!
  private var verticalPadding: CGFloat = Theme.composeAttachmentsVPadding

  // Modify updateHeight to be public and return the height
  func getHeight() -> CGFloat {
    attachments.isEmpty ? 0 : Theme.composeAttachmentImageHeight + 2 * verticalPadding
  }

  public func updateHeight(animated: Bool = false) {
    if animated {
      heightConstraint.animator().constant = getHeight()
    } else {
      heightConstraint.constant = getHeight()
    }
  }

  private func setupView() {
    clipsToBounds = true

    heightConstraint = heightAnchor.constraint(equalToConstant: getHeight())

    addSubview(stackView)

    NSLayoutConstraint.activate([
      heightConstraint,

      // no top for stack.
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  public func removeImageView(_ image: NSImage) {
    if let attachment = attachments[image] {
      attachments.removeValue(forKey: image)

      if attachments.isEmpty {
        // animate last one
        attachment.fadeOut { [weak self] in
          self?.stackView.removeArrangedSubview(attachment)
          attachment.removeFromSuperview()
        }
        return
      }

      stackView.removeArrangedSubview(attachment)
      attachment.removeFromSuperview()
    }
  }

  public func addImageView(_ image: NSImage) {
    let attachmentView = ImageAttachmentView(image: image) { [weak self] in
      self?.compose?.removeImage(image)
    }
    attachmentView.translatesAutoresizingMaskIntoConstraints = false
    attachments[image] = attachmentView

    stackView.addArrangedSubview(attachmentView)

    attachmentView.fadeIn()
  }

  public func clearViews(animated: Bool = false) {
    for (_, value) in attachments {
      stackView.removeArrangedSubview(value)
      value.removeFromSuperview()
    }
    attachments.removeAll()
  }
}

extension NSView {
  func fadeOut(completionHandler: (() -> Void)?) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      animator().alphaValue = 0
    } completionHandler: {
      completionHandler?()
    }
  }

  func fadeIn() {
    wantsLayer = true
    layer?.opacity = 0
    DispatchQueue.main.async { [weak self] in
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.allowsImplicitAnimation = true
        self?.layer?.opacity = 1
      }
    }
  }
}

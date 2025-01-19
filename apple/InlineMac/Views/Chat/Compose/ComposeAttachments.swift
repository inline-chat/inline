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
  
  // Modify updateHeight to be public and return the height
  func getHeight() -> CGFloat {
    return attachments.isEmpty ? 0 : 80 // 80 for image
  }
  
  private func setupView() {
    addSubview(stackView)
    
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }
  
  public func removeImageView(_ image: NSImage) {
    if let attachment = attachments[image] {
      stackView.removeArrangedSubview(attachment)
      attachment.removeFromSuperview()
      attachments.removeValue(forKey: image)
    }
  }
  
  public func addImageView(_ image: NSImage) {
    let attachmentView = ImageAttachmentView(image: image) { [weak self] in
      self?.compose?.removeImage(image)
    }
    attachmentView.translatesAutoresizingMaskIntoConstraints = false
    
    attachments[image] = attachmentView
    stackView.addArrangedSubview(attachmentView)
  }
  
  public func clearViews() {
    for (_, value) in attachments {
      stackView.removeArrangedSubview(value)
      value.removeFromSuperview()
    }
    attachments.removeAll()
  }
}

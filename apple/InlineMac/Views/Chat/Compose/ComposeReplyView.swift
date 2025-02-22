import AppKit
import InlineKit

// TODO: Remove alpha animation

class ComposeReplyView: NSView {
  // MARK: - Properties

  private var onClose: () -> Void
  private var kind: EmbeddedMessageView.Kind
  private var heightConstraint: NSLayoutConstraint!
  private let defaultHeight: CGFloat = Theme.embeddedMessageHeight
  private let buttonSize: CGFloat = Theme.composeButtonSize

  // MARK: - Views

  private lazy var iconView: NSView = {
    let view = NSView()
    // TODO: add a reply icon or sth
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var messageView: EmbeddedMessageView = {
    let view = EmbeddedMessageView(kind: kind)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var closeButton: NSButton = {
    let button = NSButton(frame: .zero)
    button.bezelStyle = .circular
    button.isBordered = false
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(handleClose)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }()

  // MARK: - Initialization

  init(
    kind: EmbeddedMessageView.Kind,
    onClose: @escaping () -> Void
  ) {
    self.onClose = onClose
    self.kind = kind
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    clipsToBounds = true

    addSubview(closeButton)

    heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
      closeButton.heightAnchor.constraint(equalToConstant: buttonSize),
      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),

      heightConstraint,
    ])

    addMessageView()

    // Initially hidden
    alphaValue = 0
    heightConstraint.constant = 0
  }

  private func addMessageView() {
    addSubview(messageView)
    NSLayoutConstraint.activate([
      messageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      messageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      messageView.heightAnchor.constraint(equalToConstant: defaultHeight),
    ])
  }

  // MARK: - Actions

  @objc private func handleClose() {
    close()
  }

  // MARK: - Public Methods

  func update(with fullMessage: FullMessage) {
    messageView.update(with: fullMessage.message, from: fullMessage.from!)
  }

  func open(animated: Bool = true) {
    guard alphaValue == 0 else { return }

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        heightConstraint.animator().constant = defaultHeight
        animator().alphaValue = 1
      }
    } else {
      heightConstraint.constant = defaultHeight
      alphaValue = 1
    }
  }

  func close(animated: Bool = false, completion: (() -> Void)? = nil) {
    guard alphaValue == 1 else { return }

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.completionHandler = {
          self.onClose()
          completion?()
        }

        heightConstraint.animator().constant = 0
        animator().alphaValue = 0
      }
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false

        heightConstraint.constant = 0
        alphaValue = 0
        onClose()
        completion?()
      }
    }
  }

  var isOpen: Bool {
    alphaValue == 1
  }
}

import AppKit
import InlineKit

class ComposeMessageView: NSView {
  // MARK: - Types

  enum Kind {
    case replying
    case editing
  }

  // MARK: - Properties

  private var onClose: () -> Void
  private var kind: Kind = .replying
  private var heightConstraint: NSLayoutConstraint!
  private let defaultHeight: CGFloat = Theme.embeddedMessageHeight
  private let buttonSize: CGFloat = Theme.composeButtonSize

  // MARK: - Constants

  private let hiddenAlpha: CGFloat = 0.95
  private let visibleAlpha: CGFloat = 1.0

  // MARK: - Views

  private lazy var iconView: NSView = {
    let view = NSView()
    // TODO: add a reply icon or sth
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var messageView: EmbeddedMessageView = {
    let view = EmbeddedMessageView(style: .colored)
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
    onClose: @escaping () -> Void
  ) {
    self.onClose = onClose
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

    addMessageView()

    addSubview(closeButton, positioned: .above, relativeTo: messageView)

    heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
      closeButton.heightAnchor.constraint(equalToConstant: buttonSize),
      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),

      heightConstraint,
    ])

    // Initially hidden
    alphaValue = hiddenAlpha
    heightConstraint.constant = 0
  }

  private func addMessageView() {
    addSubview(messageView)
    messageView
      .setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
      messageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      messageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      messageView.widthAnchor.constraint(equalTo: widthAnchor),
      messageView.heightAnchor.constraint(equalToConstant: defaultHeight),
    ])
  }

  // MARK: - Actions

  @objc private func handleClose() {
    close(animated: true)
    onClose()
  }

  // MARK: - Public Methods

  func update(with fullMessage: FullMessage, kind: Kind) {
    self.kind = kind

    messageView
      .update(
        with: fullMessage,
        kind: kind == .replying ? .replyingInCompose : .editingInCompose
      )
  }

  func open(animated: Bool = true) {
    guard alphaValue == hiddenAlpha else { return }

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)

        heightConstraint.animator().constant = defaultHeight
        animator().alphaValue = visibleAlpha
      }
    } else {
      heightConstraint.constant = defaultHeight
      alphaValue = visibleAlpha
    }
  }

  func close(animated: Bool = false, completion: (() -> Void)? = nil, callOnClose: Bool = true) {
    guard alphaValue == visibleAlpha else { return }

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.completionHandler = {
          if callOnClose {
            self.onClose()
          }
          completion?()
        }

        heightConstraint.animator().constant = 0
        animator().alphaValue = hiddenAlpha
      }
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false

        heightConstraint.constant = 0
        alphaValue = hiddenAlpha
        if callOnClose {
          onClose()
        }
        completion?()
      }
    }
  }

  var isOpen: Bool {
    alphaValue == visibleAlpha
  }
}

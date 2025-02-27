import AppKit
import InlineKit
import InlineUI

class EmbeddedMessageView: NSView {
  // MARK: - Constants

  private enum Constants {
    static let cornerRadius: CGFloat = 4
    static let rectangleWidth: CGFloat = 2
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 4
    static let horizontalPadding: CGFloat = 6
    static let height: CGFloat = Theme.embeddedMessageHeight
  }

  // MARK: - Properties

  enum Kind {
    case replyInMessage
    case replyingInCompose
  }

  private var kind: Kind

  private var senderFont: NSFont {
    .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  }

  private var messageFont: NSFont {
    Theme.messageTextFont
  }

  private var textColor: NSColor {
    .labelColor
  }

  // MARK: - Views

  override var wantsUpdateLayer: Bool {
    true
  }

  private lazy var rectangleView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor // use sender color
    return view
  }()

  private lazy var nameLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = senderFont
    label.lineBreakMode = .byTruncatingTail
    label.textColor = textColor
    label.heightAnchor.constraint(equalToConstant: Theme.messageNameLabelHeight).isActive = true
    return label
  }()

  private lazy var messageLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = messageFont
    label.lineBreakMode = .byTruncatingTail
    label.textColor = textColor
    label.maximumNumberOfLines = 1
    return label
  }()

  // MARK: - Initialization

  init(kind: Kind) {
    self.kind = kind
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = Constants.cornerRadius
    layer?.masksToBounds = true

    addSubview(rectangleView)
    addSubview(nameLabel)
    addSubview(messageLabel)

    NSLayoutConstraint.activate([
      // Rectangle view
      rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rectangleView.widthAnchor.constraint(equalToConstant: Constants.rectangleWidth),
      rectangleView.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding),
      rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.verticalPadding),

      // Name label
      nameLabel.leadingAnchor.constraint(
        equalTo: rectangleView.trailingAnchor, constant: Constants.contentSpacing
      ),
      nameLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -Constants.horizontalPadding
      ),
      nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding),

      // Message label
      messageLabel.leadingAnchor.constraint(
        equalTo: rectangleView.trailingAnchor, constant: Constants.contentSpacing
      ),
      messageLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -Constants.horizontalPadding
      ),
      messageLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
      messageLabel.bottomAnchor.constraint(
        equalTo: bottomAnchor, constant: -Constants.verticalPadding
      ),
    ])
  }

  func update(with message: Message, from: User, file: File?) {
    let senderName = from.fullName
    nameLabel.stringValue = switch kind {
      case .replyInMessage:
        "\(senderName)"

      case .replyingInCompose:
        "Reply to \(senderName)"
    }
    nameLabel.textColor = NSColor(InitialsCircle.ColorPalette.color(for: senderName))
    
    if let text = message.text, !text.isEmpty {
      messageLabel.stringValue = text
    } else if let file {
      messageLabel.stringValue = file.fileType == .photo ? "🖼️ Photo" : "📄 File"
    } else {
      messageLabel.stringValue = "Empty message"
    }
  }
}

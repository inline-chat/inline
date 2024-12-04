import InlineKit
import UIKit

class UIMessageView: UIView {
  // MARK: - Properties

  private let messageLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 16)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let bubbleView: UIView = {
    let view = UIView()
    view.layer.cornerRadius = 18
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let containerView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var fullMessage: FullMessage

  // MARK: - Initialization

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)
    setupViews()
    configureForMessage()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    addSubview(containerView)
    containerView.addSubview(bubbleView)
    bubbleView.addSubview(messageLabel)

    NSLayoutConstraint.activate([
      // Container constraints
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),

      // Bubble constraints
      bubbleView.topAnchor.constraint(equalTo: containerView.topAnchor),
      bubbleView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
      bubbleView.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

      // Message label constraints - centered
      messageLabel.centerXAnchor.constraint(equalTo: bubbleView.centerXAnchor),
      messageLabel.centerYAnchor.constraint(equalTo: bubbleView.centerYAnchor),
      messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
      messageLabel.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor, constant: -8
      ),
      messageLabel.leadingAnchor.constraint(
        equalTo: bubbleView.leadingAnchor, constant: 10
      ),
      messageLabel.trailingAnchor.constraint(
        equalTo: bubbleView.trailingAnchor, constant: -10
      ),

    ])

    // Add gesture recognizer for context menu
    let interaction = UIContextMenuInteraction(delegate: self)
    bubbleView.addInteraction(interaction)
  }

  private func configureForMessage() {
    messageLabel.text = fullMessage.message.text

    // Set text alignment based on content
    if let text = fullMessage.message.text, text.isRTL {
      messageLabel.textAlignment = .right
    } else {
      messageLabel.textAlignment = .left
    }

    if fullMessage.message.out == true {
      messageLabel.textColor = .white
      bubbleView.backgroundColor = .tintColor

      // Right aligned
      bubbleView.leadingAnchor.constraint(
        greaterThanOrEqualTo: containerView.leadingAnchor, constant: 60
      ).isActive = true
      bubbleView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor).isActive = true
    } else {
      messageLabel.textColor = .label
      bubbleView.backgroundColor = UIColor.systemGray6.withAlphaComponent(0.7)

      // Left aligned
      bubbleView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor).isActive = true
      bubbleView.trailingAnchor.constraint(
        lessThanOrEqualTo: containerView.trailingAnchor, constant: -60
      ).isActive = true
    }
  }

  // MARK: - Size Calculation

  override func layoutSubviews() {
    super.layoutSubviews()
    invalidateIntrinsicContentSize()
  }
}

// MARK: - Context Menu

extension UIMessageView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      let copyAction = UIAction(title: "Copy") { [weak self] _ in
        UIPasteboard.general.string = self?.fullMessage.message.text
      }
      return UIMenu(children: [copyAction])
    }
  }
}

extension String {
  var isRTL: Bool {
    guard let firstChar = first else { return false }
    let earlyRTL =
      firstChar.unicodeScalars.first?.properties.generalCategory == .otherLetter
        && firstChar.unicodeScalars.first != nil && firstChar.unicodeScalars.first!.value >= 0x0590
        && firstChar.unicodeScalars.first!.value <= 0x08FF

    if earlyRTL { return true }

    let language = CFStringTokenizerCopyBestStringLanguage(
      self as CFString, CFRange(location: 0, length: count)
    )
    if let language = language {
      return NSLocale.characterDirection(forLanguage: language as String) == .rightToLeft
    }
    return false
  }
}

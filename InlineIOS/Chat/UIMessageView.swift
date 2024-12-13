import InlineKit
import SwiftUI
import UIKit

class UIMessageView: UIView {
  // MARK: - Properties

  private let messageLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 16, weight: .medium)
    label.textAlignment = .natural
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let bubbleView: UIView = {
    let view = UIView()
    view.layer.cornerRadius = 18
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let metadataView: MessageMetadata = {
    let metadata = MessageMetadata(date: Date(), status: nil, isOutgoing: false)
    metadata.translatesAutoresizingMaskIntoConstraints = false
    return metadata
  }()

  private var leadingConstraint: NSLayoutConstraint?
  private var trailingConstraint: NSLayoutConstraint?
  private var fullMessage: FullMessage

  private let horizontalPadding: CGFloat = 12
  private let verticalPadding: CGFloat = 8

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
    addSubview(bubbleView)
    bubbleView.addSubview(messageLabel)
    bubbleView.addSubview(metadataView)

    let leading = bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor)
    let trailing = bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor)

    leadingConstraint = leading
    trailingConstraint = trailing

    var fuckingConstraints = [
      bubbleView.topAnchor.constraint(equalTo: topAnchor),
      bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),
      bubbleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),

      messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: verticalPadding),
      messageLabel.leadingAnchor.constraint(
        equalTo: bubbleView.leadingAnchor, constant: horizontalPadding
      ),
      messageLabel.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor, constant: -verticalPadding
      ),
      metadataView.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor
      ),
      metadataView.leadingAnchor.constraint(equalTo: messageLabel.trailingAnchor, constant: 8),
      metadataView.trailingAnchor.constraint(
        equalTo: bubbleView.trailingAnchor, constant: -horizontalPadding
      ),
      metadataView.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),
    ]

    NSLayoutConstraint.activate(fuckingConstraints)

    messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    metadataView.setContentCompressionResistancePriority(.required, for: .horizontal)
    metadataView.setContentHuggingPriority(.required, for: .horizontal)

    let interaction = UIContextMenuInteraction(delegate: self)
    bubbleView.addInteraction(interaction)
  }

  private func configureForMessage() {
    messageLabel.text = fullMessage.message.text

    if fullMessage.message.out == true {
      bubbleView.backgroundColor = ColorManager.shared.selectedColor
      leadingConstraint?.isActive = false
      trailingConstraint?.isActive = true
      messageLabel.textColor = .white
      metadataView.configure(
        date: fullMessage.message.date,
        status: fullMessage.message.status,
        isOutgoing: true
      )
    } else {
      bubbleView.backgroundColor = UIColor.systemGray6.withAlphaComponent(0.7)
      leadingConstraint?.isActive = true
      trailingConstraint?.isActive = false
      messageLabel.textColor = .label
      metadataView.configure(
        date: fullMessage.message.date,
        status: nil,
        isOutgoing: false
      )
    }
  }

  func updateLayout() {
    setNeedsLayout()
    layoutIfNeeded()
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)

    if previousTraitCollection?.preferredContentSizeCategory
      != traitCollection.preferredContentSizeCategory
    {
      setNeedsLayout()
    }
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

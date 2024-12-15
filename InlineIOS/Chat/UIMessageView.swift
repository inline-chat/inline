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
    return label
  }()

  private let bubbleView: UIView = {
    let view = UIView()
    view.layer.cornerRadius = 18
    return view
  }()

  private let metadataView: MessageMetadata = {
    let metadata = MessageMetadata(date: Date(), status: nil, isOutgoing: false)
    return metadata
  }()

  private lazy var contentStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var shortMessageStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 8
    stack.alignment = .center
    return stack
  }()

  private var leadingConstraint: NSLayoutConstraint?
  private var trailingConstraint: NSLayoutConstraint?
  private var fullMessage: FullMessage

  private let horizontalPadding: CGFloat = 12
  private let verticalPadding: CGFloat = 8

  private let embedView: UIHostingController<MessageEmbedView>? = nil

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
    bubbleView.translatesAutoresizingMaskIntoConstraints = false

    bubbleView.addSubview(contentStack)

    leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
    trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)

    // Base constraints
    NSLayoutConstraint.activate([
      bubbleView.topAnchor.constraint(equalTo: topAnchor),
      bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),
      bubbleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),

      contentStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: verticalPadding),
      contentStack.leadingAnchor.constraint(
        equalTo: bubbleView.leadingAnchor, constant: horizontalPadding
      ),
      contentStack.trailingAnchor.constraint(
        equalTo: bubbleView.trailingAnchor, constant: -horizontalPadding
      ),
      contentStack.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor, constant: -verticalPadding
      ),
    ])

    let interaction = UIContextMenuInteraction(delegate: self)
    bubbleView.addInteraction(interaction)
  }

  private func updateMetadataLayout() {
    // Remove existing arrangement
    contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    shortMessageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

    // Add embed view if message is a reply
    if let repliedToMessageId = fullMessage.message.repliedToMessageId {
      let embedView = UIHostingController(
        rootView: MessageEmbedView(repliedToMessageId: repliedToMessageId)
      )
      embedView.view.backgroundColor = UIColor.clear

      // Create container with leading alignment
      let embedContainer = UIView()
      embedContainer.addSubview(embedView.view)
      embedView.view.translatesAutoresizingMaskIntoConstraints = false

      NSLayoutConstraint.activate([
        embedView.view.topAnchor.constraint(equalTo: embedContainer.topAnchor),
        embedView.view.leadingAnchor.constraint(equalTo: embedContainer.leadingAnchor),
        embedView.view.trailingAnchor.constraint(equalTo: embedContainer.trailingAnchor),
        embedView.view.bottomAnchor.constraint(equalTo: embedContainer.bottomAnchor),
      ])

      contentStack.addArrangedSubview(embedContainer)
    }

    let messageLength = fullMessage.message.text?.count ?? 0
    let messageText = fullMessage.message.text ?? ""
    let hasLineBreak = messageText.contains("\n")
    if messageLength > 22 || hasLineBreak {
      // Long message layout: Vertical stack with metadata at bottom
      contentStack.addArrangedSubview(messageLabel)
      contentStack.addArrangedSubview(metadataView)

      // Align metadata to trailing
      metadataView.setContentHuggingPriority(.required, for: .horizontal)
      metadataView.setContentCompressionResistancePriority(.required, for: .horizontal)

      let metadataContainer = UIView()
      metadataContainer.addSubview(metadataView)
      metadataView.translatesAutoresizingMaskIntoConstraints = false

      NSLayoutConstraint.activate([
        metadataView.trailingAnchor.constraint(equalTo: metadataContainer.trailingAnchor),
        metadataView.topAnchor.constraint(equalTo: metadataContainer.topAnchor),
        metadataView.bottomAnchor.constraint(equalTo: metadataContainer.bottomAnchor),
      ])

      contentStack.addArrangedSubview(metadataContainer)
    } else {
      // Short message layout: Horizontal stack
      shortMessageStack.addArrangedSubview(messageLabel)
      shortMessageStack.addArrangedSubview(metadataView)
      contentStack.addArrangedSubview(shortMessageStack)
    }
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

    updateMetadataLayout()
  }

  func updateLayout() {
    setNeedsLayout()
    layoutIfNeeded()
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
  }

  //  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
  //    super.traitCollectionDidChange(previousTraitCollection)
  //
  //    if previousTraitCollection?.preferredContentSizeCategory
  //      != traitCollection.preferredContentSizeCategory
  //    {
  //      setNeedsLayout()
  //    }
  //  }
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

      let replyAction = UIAction(title: "Reply") { [weak self] _ in
        ChatState.shared.setReplyingMessageId(
          chatId: self?.fullMessage.message.chatId ?? 0, id: self?.fullMessage.message.id ?? 0
        )
      }

      return UIMenu(children: [copyAction, replyAction])
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

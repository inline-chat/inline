import ContextMenuAuxiliaryPreview
import InlineKit
import SwiftUI
import UIKit

class UIMessageView: UIView {
  // MARK: - Properties

  private var interaction: UIContextMenuInteraction?

  private let messageLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 17)
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
  var fullMessage: FullMessage

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
    bubbleView.translatesAutoresizingMaskIntoConstraints = false

    bubbleView.addSubview(contentStack)

    leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
    trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)

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

    setupContextMenu()
  }

  private func setupContextMenu() {
    let interaction = UIContextMenuInteraction(delegate: self)
    self.interaction = interaction
    bubbleView.addInteraction(interaction)
  }

  private func updateMetadataLayout() {
    contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    shortMessageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

    let messageLength = fullMessage.message.text?.count ?? 0
    let messageText = fullMessage.message.text ?? ""
    let hasLineBreak = messageText.contains("\n")

    if messageLength > 22 || hasLineBreak {
      contentStack.addArrangedSubview(messageLabel)

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
      bubbleView.backgroundColor = UIColor.systemGray5.withAlphaComponent(0.4)
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
}

// MARK: - Context Menu

extension UIMessageView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return nil }

      let copyAction = UIAction(title: "Copy") { _ in
        UIPasteboard.general.string = self.fullMessage.message.text
      }

      let replyAction = UIAction(title: "Reply") { _ in
        ChatState.shared.setReplyingMessageId(
          chatId: self.fullMessage.message.chatId ?? 0,
          id: self.fullMessage.message.id ?? 0
        )
      }

      return UIMenu(children: [copyAction])
    }
  }
}

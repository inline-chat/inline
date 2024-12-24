import InlineKit
import SwiftUI
import UIKit

struct Reaction2: Equatable {
  let emoji: String
  var count: Int
  var hasReacted: Bool
}

class UIMessageView: UIView {
  // MARK: - Properties

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

  private var reactions: [Reaction2] = []
  private let reactionHeight: CGFloat = 24

  private lazy var reactionsContainer: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
    stack.distribution = .fillProportionally
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
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

    // Add reactions container if there are reactions
    if !reactions.isEmpty {
      contentStack.addArrangedSubview(reactionsContainer)
    }
  }

  private func configureForMessage() {
    messageLabel.text =
      "\(fullMessage.message.text) \(fullMessage.message.messageId) \(fullMessage.message.chatId)"

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

  func updateLayout() {
    setNeedsLayout()
    layoutIfNeeded()
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
  }

  // MARK: - Reaction2 Handling

  private func handleReaction2(_ emoji: String) {
    if let index = reactions.firstIndex(where: { $0.emoji == emoji }) {
      // Toggle existing reaction
      var reaction = reactions[index]
      reaction.hasReacted.toggle()
      reaction.count += reaction.hasReacted ? 1 : -1

      if reaction.count > 0 {
        reactions[index] = reaction
      } else {
        reactions.remove(at: index)
      }
    } else {
      // Add new reaction
      reactions.append(Reaction2(emoji: emoji, count: 1, hasReacted: true))
    }

    updateReaction2Views()
  }

  private func updateReaction2Views() {
    // Clear existing reaction views
    reactionsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

    // Add reaction bubbles
    for reaction in reactions {
      let reactionView = createReaction2Bubble(for: reaction)
      reactionsContainer.addArrangedSubview(reactionView)
    }

    updateMetadataLayout()
  }

  private func createReaction2Bubble(for reaction: Reaction2) -> UIView {
    let container = UIView()
    container.backgroundColor =
      reaction.hasReacted ? ColorManager.shared.selectedColor.withAlphaComponent(0.1) : .systemGray6
    container.layer.cornerRadius = reactionHeight / 2

    let label = UILabel()
    label.text = "\(reaction.emoji) \(reaction.count)"
    label.font = .systemFont(ofSize: 12)
    label.textAlignment = .center

    container.addSubview(label)
    label.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      container.heightAnchor.constraint(equalToConstant: reactionHeight),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    // Add tap gesture
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(reactionTapped(_:)))
    container.addGestureRecognizer(tapGesture)
    container.tag = reactions.firstIndex(where: { $0.emoji == reaction.emoji }) ?? 0

    return container
  }

  @objc private func reactionTapped(_ gesture: UITapGestureRecognizer) {
    guard let view = gesture.view,
          reactions.indices.contains(view.tag)
    else { return }

    handleReaction2(reactions[view.tag].emoji)
  }
}

// MARK: - Context Menu

extension UIMessageView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      let copyAction = UIAction(title: "Copy") { [weak self] _ in
        UIPasteboard.general.string = self?.fullMessage.message.text
      }

      let replyAction = UIAction(title: "Reply") { [weak self] _ in
        ChatState.shared.setReplyingMessageId(
          chatId: self?.fullMessage.message.chatId ?? 0,
          id: self?.fullMessage.message.id ?? 0
        )
      }

      // Create reaction submenu
      let reactionActions = self?.createReaction2Actions() ?? []
      let reactMenu = UIMenu(
        title: "React", image: UIImage(systemName: "face.smiling"), children: reactionActions
      )

      return UIMenu(children: [copyAction, replyAction, reactMenu])
    }
  }

  private func createReaction2Actions() -> [UIAction] {
    let commonEmojis = ["👍", "❤️", "😂", "🎉", "🤔", "👀"]

    return commonEmojis.map { emoji in
      UIAction(title: emoji) { [weak self] _ in
        self?.handleReaction2(emoji)
      }
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

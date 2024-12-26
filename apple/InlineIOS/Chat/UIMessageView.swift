import ContextMenuAuxiliaryPreview
import InlineKit
import SwiftUI
import UIKit

struct GroupedReaction {
  let emoji: String
  let count: Int
  let isFromCurrentUser: Bool
}

extension String {
  var isRTL: Bool {
    guard let firstChar = first else { return false }
    let earlyRTL = firstChar.unicodeScalars.first?.properties.generalCategory == .otherLetter
      && firstChar.unicodeScalars.first != nil
      && firstChar.unicodeScalars.first!.value >= 0x0590
      && firstChar.unicodeScalars.first!.value <= 0x08FF
        
    if earlyRTL { return true }
        
    let language = CFStringTokenizerCopyBestStringLanguage(
      self as CFString,
      CFRange(location: 0, length: count)
    )
    if let language = language {
      return NSLocale.characterDirection(forLanguage: language as String) == .rightToLeft
    }
    return false
  }
}

class UIMessageView: UIView {
  // MARK: - Properties
    
  private var interaction: UIContextMenuInteraction?
  private var contextMenuManager: ContextMenuManager?
    
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
    
  private let reactionsContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
    
  private let reactionsStackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
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
        
    setupReactionsView()
        
    leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
    trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        
    NSLayoutConstraint.activate([
      bubbleView.topAnchor.constraint(equalTo: topAnchor),
      bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),
      bubbleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            
      contentStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: verticalPadding),
      contentStack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: horizontalPadding),
      contentStack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -horizontalPadding),
      contentStack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -verticalPadding),
    ])
        
    setupContextMenu()
  }
    
  private func setupContextMenu() {
    let interaction = UIContextMenuInteraction(delegate: self)
    self.interaction = interaction
    bubbleView.addInteraction(interaction)
        
    let contextMenuManager = ContextMenuManager(
      contextMenuInteraction: interaction,
      menuTargetView: self
    )
        
    self.contextMenuManager = contextMenuManager
    contextMenuManager.delegate = self
        
    contextMenuManager.auxiliaryPreviewConfig = AuxiliaryPreviewConfig(
      verticalAnchorPosition: .automatic,
      horizontalAlignment: fullMessage.message.out == true ? .targetTrailing : .targetLeading,
      preferredWidth: .constant(320),
      preferredHeight: .constant(46),
      marginInner: 16,
      marginOuter: 12,
      transitionConfigEntrance: .syncedToMenuEntranceTransition(),
      transitionExitPreset: .fade
    )
  }
    
  private func setupReactionsView() {
    reactionsContainer.addSubview(reactionsStackView)
        
    NSLayoutConstraint.activate([
      reactionsStackView.topAnchor.constraint(equalTo: reactionsContainer.topAnchor),
      reactionsStackView.leadingAnchor.constraint(equalTo: reactionsContainer.leadingAnchor),
      reactionsStackView.trailingAnchor.constraint(equalTo: reactionsContainer.trailingAnchor),
      reactionsStackView.bottomAnchor.constraint(equalTo: reactionsContainer.bottomAnchor),
    ])
  }
    
  private func updateMetadataLayout() {
    contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    shortMessageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
    let messageLength = fullMessage.message.text?.count ?? 0
    let messageText = fullMessage.message.text ?? ""
    let hasLineBreak = messageText.contains("\n")
        
    if messageLength > 22 || hasLineBreak {
      contentStack.addArrangedSubview(messageLabel)
      updateReactions()
            
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
      updateReactions()
    }
  }
    
  private func updateReactions() {
    reactionsStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
    let groupedReactions = groupReactions(fullMessage.reactions)
        
    for reaction in groupedReactions {
      let reactionView = createReactionView(for: reaction)
      reactionsStackView.addArrangedSubview(reactionView)
    }
        
    if !groupedReactions.isEmpty {
      contentStack.addArrangedSubview(reactionsContainer)
    } else {
      reactionsContainer.removeFromSuperview()
    }
  }
    
  private func groupReactions(_ reactions: [Reaction]) -> [GroupedReaction] {
    var groupedDict: [String: (count: Int, fromCurrentUser: Bool)] = [:]
        
    for reaction in reactions {
      let current = groupedDict[reaction.emoji] ?? (0, false)
      let isFromCurrentUser = reaction.userId == Auth.shared.getCurrentUserId()
      groupedDict[reaction.emoji] = (
        current.count + 1,
        current.fromCurrentUser || isFromCurrentUser
      )
    }
        
    return groupedDict.map { emoji, info in
      GroupedReaction(
        emoji: emoji,
        count: info.count,
        isFromCurrentUser: info.fromCurrentUser
      )
    }.sorted { $0.count > $1.count }
  }
    
  private func createReactionView(for reaction: GroupedReaction) -> UIView {
    let container = UIView()
    container.backgroundColor = reaction.isFromCurrentUser ?
      ColorManager.shared.selectedColor.withAlphaComponent(0.1) :
      UIColor.systemGray5.withAlphaComponent(0.5)
    container.layer.cornerRadius = 12
        
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
        
    let emojiLabel = UILabel()
    emojiLabel.text = reaction.emoji
    emojiLabel.font = .systemFont(ofSize: 14)
        
    let countLabel = UILabel()
    countLabel.text = "\(reaction.count)"
    countLabel.font = .systemFont(ofSize: 12, weight: .medium)
    countLabel.textColor = reaction.isFromCurrentUser ?
      ColorManager.shared.selectedColor :
      .secondaryLabel
        
    stack.addArrangedSubview(emojiLabel)
    stack.addArrangedSubview(countLabel)
        
    container.addSubview(stack)
        
    NSLayoutConstraint.activate([
      container.heightAnchor.constraint(equalToConstant: 24),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
    ])
        
    container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(reactionTapped(_:))))
    container.tag = reaction.emoji.hashValue
        
    return container
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
    
  // MARK: - Actions
    
  @objc private func reactionTapped(_ gesture: UITapGestureRecognizer) {
    guard let view = gesture.view,
          let emoji = groupReactions(fullMessage.reactions)
          .first(where: { $0.emoji.hashValue == view.tag })?.emoji
    else {
      return
    }
        
    UIView.animate(withDuration: 0.1, animations: {
      view.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
    }) { _ in
      UIView.animate(withDuration: 0.1) {
        view.transform = .identity
      }
    }
        
    Task {
      do {
        try await DataManager.shared.addReaction(
          messageId: fullMessage.message.messageId,
          chatId: fullMessage.message.chatId,
          emoji: emoji
        )
      } catch {
        print("Error toggling reaction: \(error)")
      }
    }
  }
    
  @objc private func buttonTouchDown(_ sender: UIButton) {
    UIView.animate(withDuration: 0.1) {
      sender.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
      sender.alpha = 0.7
    }
  }
    
  @objc private func buttonTouchUp(_ sender: UIButton) {
    UIView.animate(withDuration: 0.1) {
      sender.transform = .identity
      sender.alpha = 1.0
    }
  }
    
  @objc private func reactionButtonTapped(_ sender: UIButton) {
    guard let emoji = sender.title(for: .normal) else { return }
        
    Task {
      do {
        try await DataManager.shared.addReaction(
          messageId: fullMessage.message.messageId,
          chatId: fullMessage.message.chatId,
          emoji: emoji
        )
      } catch {
        print("Error adding reaction: \(error)")
      }
    }
  }
}

// MARK: - Context Menu

extension UIMessageView: UIContextMenuInteractionDelegate, ContextMenuManagerDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    contextMenuManager?.notifyOnContextMenuInteraction(
      interaction,
      configurationForMenuAtLocation: location
    )
        
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
    
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    contextMenuManager?.notifyOnContextMenuInteraction(
      interaction,
      willDisplayMenuFor: configuration,
      animator: animator
    )
  }
    
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    contextMenuManager?.notifyOnContextMenuInteraction(
      interaction,
      willEndFor: configuration,
      animator: animator
    )
  }
    
  func onRequestMenuAuxiliaryPreview(sender: ContextMenuManager) -> UIView? {
    let previewView = UIView()
    previewView.backgroundColor = .clear
    previewView.layer.cornerRadius = 25
        
    let blurEffect = UIBlurEffect(style: .systemMaterial)
    let blurView = UIVisualEffectView(effect: blurEffect)
    blurView.layer.cornerRadius = 25
    blurView.clipsToBounds = true
    blurView.translatesAutoresizingMaskIntoConstraints = false
    previewView.addSubview(blurView)
        
    let contentView = blurView.contentView
        
    let reactions = ["👍", "👎", "❤️", "🥸", "🔥", "🥹", "👋", "🤩"]
    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.distribution = .fillEqually
    stackView.spacing = 12
    stackView.translatesAutoresizingMaskIntoConstraints = false
        
    for reaction in reactions {
      let container = UIView()
      container.translatesAutoresizingMaskIntoConstraints = false
            
      let button = UIButton()
      button.setTitle(reaction, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 24)
      button.addTarget(self, action: #selector(reactionButtonTapped(_:)), for: .touchUpInside)
      button.addTarget(self, action: #selector(buttonTouchDown(_:)), for: .touchDown)
      button.addTarget(self, action: #selector(buttonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      button.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(button)
            
      NSLayoutConstraint.activate([
        button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        button.widthAnchor.constraint(equalToConstant: 40),
        button.heightAnchor.constraint(equalToConstant: 40),
      ])
            
      stackView.addArrangedSubview(container)
    }
        
    contentView.addSubview(stackView)
        
    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: previewView.topAnchor),
      blurView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
            
      stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
      stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
      stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            
      previewView.heightAnchor.constraint(equalToConstant: 46),
    ])
        
    previewView.layer.shadowColor = UIColor.black.cgColor
    previewView.layer.shadowOffset = CGSize(width: 0, height: 2)
    previewView.layer.shadowRadius = 4
    previewView.layer.shadowOpacity = 0.1
        
    return previewView
  }
}

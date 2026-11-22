import ObjectiveC
import MCEmojiPicker
import InlineCompatUI
import Auth
import ContextMenuAccessoryStructs
import InlineIOSUI
import InlineKit
import InlineUI
import Logger
import SwiftUI
import TextProcessing
import UIKit

/// What a message's menu offers and does: the actions menu, the reaction picker, and the sheets,
/// alerts and requests behind them. Shared by both message lists; each list supplies where to
/// present, how to find the current copy of a message, and how a reaction waits for its open menu.
@MainActor
final class MessageMenuActions: NSObject {
  let peerId: Peer
  let spaceId: Int64?
  var theme: IOSThemeSnapshot

  /// The view controller sheets and alerts are presented from.
  var presenter: () -> UIViewController? = { nil }
  /// The width the reaction picker sizes itself for.
  var containerWidth: () -> CGFloat = { UIScreen.main.bounds.width }
  /// The message as the list holds it now, by stable id, server id or random id.
  var currentMessage: (_ stableId: Int64, _ messageId: Int64, _ chatId: Int64, _ randomId: Int64?) -> FullMessage? = {
    _, _, _, _ in nil
  }
  /// Runs a reaction toggle from an open menu, which the list keeps up until the row has it.
  var react: (_ stableId: Int64, _ toggle: () -> Void) -> Void = { _, toggle in toggle() }
  /// The window the emoji sheet goes over when a menu is open, if any.
  var emojiSheetOverWindow: () -> UIWindow? = { nil }
  /// The emoji sheet closed.
  var onEmojiSheetDismissed: () -> Void = {}

  private var hasLinearConnected = false
  private var linearTeamId: String?
  /// `ReactionEmojiPickerPresentation` (iOS 17+), stored untyped for the iOS 15 build.
  private var reactionPickerPresentation: AnyObject?

  init(peerId: Peer, spaceId: Int64?, theme: IOSThemeSnapshot) {
    self.peerId = peerId
    self.spaceId = spaceId
    self.theme = theme
    super.init()
  }

  var isReactionPickerPresented: Bool { reactionPickerPresentation != nil }

  private var validSpaceId: Int64? {
    guard let spaceId, spaceId > 0 else { return nil }
    return spaceId
  }

  // MARK: - Integrations

  /// Asks which integrations this chat can use, for the Notion and Linear actions.
  func loadIntegrations() {
    NotionTaskManager.shared.delegate = self
    let peerId = peerId
    let scopedSpaceId = peerId.isThread ? validSpaceId : nil
    Task {
      do {
        let integrations = try await InlineRPCClient.shared.integrations(
          userID: Auth.shared.getCurrentUserId() ?? 0,
          spaceID: scopedSpaceId
        )
        await NotionTaskManager.shared.checkIntegrationAccess(
          peerId: peerId,
          spaceId: scopedSpaceId,
          integrations: integrations
        )
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          hasLinearConnected = peerId.isThread
            ? integrations.hasLinearConnected
            : (integrations.linearSpaces?.isEmpty == false)
          linearTeamId = integrations.linearTeamId
        }
      } catch {
        NotionTaskManager.shared.clearIntegrationAccess()
        DispatchQueue.main.async { [weak self] in
          self?.hasLinearConnected = false
          self?.linearTeamId = nil
        }
      }
    }
  }

  // MARK: - Menus

  func serviceMenu(for message: Message) -> UIMenu {
    let replyAction = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
      ChatState.shared.setReplyingMessageId(peer: message.peerId, id: message.messageId)
    }
    let deleteAction = UIAction(
      title: "Delete",
      image: UIImage(systemName: "trash"),
      attributes: .destructive
    ) { [weak self] _ in
      self?.showDeleteConfirmation(messageId: message.messageId, peerId: message.peerId, chatId: message.chatId)
    }
    return UIMenu(children: [replyAction, deleteAction])
  }

  /// `includesTextCopy` is false while the custom menu offers a copy of selected text instead.
  /// `photo` is the image the row shows now; `openDocument` opens a downloaded document;
  /// `richCopy` is the row's rich body as copy blocks, when it shows one.
  func actionsMenu(
    for fullMessage: FullMessage,
    photo: @escaping () -> UIImage?,
    openDocument: (() -> Void)? = nil,
    richCopy: (() -> MessageClipboardDocument?)? = nil,
    includeReactionsAction: Bool = false,
    includesTextCopy: Bool = true,
    offersSelectText: Bool = false
  ) -> UIMenu {
    let message = fullMessage.message
    let isMessageSending = message.status == .sending
    let isMessageFailed = message.status == .failed

    var actions: [UIAction] = []

    if message.hasText, includesTextCopy {
      let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "square.on.square")) { _ in
        // A rich body copies its blocks, so headings, lists, code and tables keep their shape.
        if let document = richCopy?(), MessageClipboard.write(document) { return }
        guard let text = fullMessage.displayText else {
          UIPasteboard.general.string = message.text
          return
        }
        MessageTextPasteboard.copy(
          text: text,
          entities: fullMessage.translationEntities ?? message.entities
        )
      }
      actions.append(copyAction)
    }

    // Where the menu can't select in place (text still streaming in, older rows), a sheet
    // offers the text to select from instead.
    if offersSelectText, message.hasText, let text = fullMessage.displayText ?? message.text {
      let entities = fullMessage.translationEntities ?? message.entities
      let canQuote = !message.isServiceMessage && !isMessageSending && !isMessageFailed
      actions.append(UIAction(
        title: "Select Text",
        image: UIImage(systemName: "selection.pin.in.out")
      ) { [weak self] _ in
        guard let presenter = self?.presenter() else { return }
        let sheet = MessageSelectTextSheet.make(
          text: text,
          entities: entities,
          onQuote: canQuote ? { selected in
            ChatState.shared.quote(
              peer: message.peerId,
              id: message.messageId,
              markdown: MessageMarkdown.quoteLines(selected)
            )
          } : nil
        )
        presenter.present(sheet, animated: true)
      })
    }

    let copyPhotoAction = UIAction(
      title: "Copy Photo",
      image: UIImage(systemName: "doc.on.clipboard")
    ) { _ in
      if let image = photo() {
        UIPasteboard.general.image = image
        ToastManager.shared.showToast("Photo copied to clipboard", type: .success, systemImage: "doc.on.clipboard")
      }
    }

    if isMessageSending {
      if fullMessage.photoInfo != nil { actions.append(copyPhotoAction) }
      let cancelAction = UIAction(
        title: fullMessage.showsPhotoUploadProgress ? "Cancel Upload" : "Cancel",
        image: fullMessage.showsPhotoUploadProgress ? UIImage(systemName: "xmark.circle") : nil,
        attributes: .destructive
      ) { _ in
        PendingMessageCanceller.cancel(fullMessage)
      }
      actions.append(cancelAction)
      return UIMenu(children: actions)
    }

    if isMessageFailed {
      if fullMessage.photoInfo != nil { actions.append(copyPhotoAction) }
      if let openDocument, let document = fullMessage.documentInfo?.document, let localPath = document.localPath,
         FileManager.default.fileExists(atPath: FileHelpers.getLocalCacheDirectory(for: .documents)
           .appendingPathComponent(localPath).path)
      {
        actions.append(UIAction(title: "Open Document", image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in
          openDocument()
        })
      }
      actions.append(UIAction(title: "Resend", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
        self?.resendMessage(fullMessage)
      })
      actions.append(UIAction(title: "Delete", attributes: .destructive) { [weak self] _ in
        self?.showDeleteConfirmationForFailed(
          messageId: message.messageId, peerId: message.peerId, chatId: message.chatId
        )
      })
      return UIMenu(children: actions)
    }

    if fullMessage.photoInfo != nil {
      actions.append(copyPhotoAction)
      actions.append(UIAction(
        title: "Save Photo",
        image: UIImage(systemName: "square.and.arrow.down")
      ) { _ in
        if let image = photo() {
          UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
          ToastManager.shared.showToast("Photo saved to Photos Library", type: .success, systemImage: "photo")
        } else {
          ToastManager.shared.showToast(
            "Failed to save photo", type: .error, systemImage: "exclamationmark.triangle"
          )
        }
      })
    }

    if includeReactionsAction {
      actions.append(UIAction(title: "Reactions", image: UIImage(systemName: "face.smiling")) { [weak self] _ in
        self?.showReactionEmojiPicker(for: fullMessage)
      })
    }

    actions.append(UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
      ChatState.shared.setReplyingMessageId(peer: message.peerId, id: message.messageId)
    })

    actions.append(UIAction(
      title: message.isSubthreadPlacement ? "Open Subthread" : "Reply in Thread",
      image: UIImage(systemName: "arrowshape.turn.up.left.circle")
    ) { _ in
      ReplyThreadNavigator.open(message: message, source: .menu)
    })

    if !message.isSubthreadPlacement {
      actions.append(UIAction(
        title: "Forward",
        image: UIImage(systemName: "arrowshape.turn.up.right")
      ) { [weak self] _ in
        self?.presentForwardSheet(fullMessage)
      })
    }

    let pinned = message.pinned == true
    let pinAction = UIAction(
      title: pinned ? "Unpin" : "Pin",
      image: UIImage(systemName: pinned ? "pin.slash" : "pin")
    ) { [weak self] _ in
      self?.togglePinMessage(message, unpin: pinned)
    }

    var editAction: UIAction?
    if message.fromId == Auth.shared.getCurrentUserId() ?? 0, message.hasText, !message.isGridTranscript {
      editAction = UIAction(title: "Edit", image: UIImage(systemName: "bubble.and.pencil")) { _ in
        ChatState.shared.setEditingMessageId(peer: message.peerId, id: message.messageId)
      }
    }

    let deleteAction = UIAction(
      title: "Delete",
      image: UIImage(systemName: "trash"),
      attributes: .destructive
    ) { [weak self] _ in
      self?.showDeleteConfirmation(messageId: message.messageId, peerId: message.peerId, chatId: message.chatId)
    }

    var menuChildren: [UIMenuElement] = []
    var basicActions = actions
    if let editAction { basicActions.append(editAction) }
    basicActions.append(pinAction)
    if !basicActions.isEmpty {
      menuChildren.append(UIMenu(title: "", options: .displayInline, children: basicActions))
    }

    let integrationActions = [notionTaskAction(for: message), linearIssueAction(for: message)].compactMap(\.self)
    if !integrationActions.isEmpty {
      menuChildren.append(UIMenu(
        title: "Actions",
        image: UIImage(systemName: "ellipsis.circle"),
        children: integrationActions
      ))
    }

    menuChildren.append(UIMenu(title: "", options: .displayInline, children: [deleteAction]))

    if let via = fullMessage.viaPresentation {
      let viaAction = UIAction(
        title: via.detail(senderName: fullMessage.senderInfo?.user.shortDisplayName),
        image: UIImage(systemName: "sparkles"),
        attributes: .disabled
      ) { _ in }
      menuChildren.append(UIMenu(title: "", options: .displayInline, children: [viaAction]))
    }

    if let attribution = fullMessage.acknowledgementAttributionLabel {
      let attributionAction = UIAction(
        title: attribution,
        image: UIImage(systemName: "person.2"),
        attributes: .disabled
      ) { _ in }
      menuChildren.append(UIMenu(title: "", options: .displayInline, children: [attributionAction]))
    }

    return UIMenu(children: menuChildren)
  }

  // MARK: - Reactions

  func reactionPicker(for fullMessage: FullMessage) -> UIView {
    let preferredSkinTone = EmojiSkinTonePreferenceStore.current()
    var seenReactions = Set<String>()
    let usualReactions = ReactionPickerEmojiUsageStore.suggestedEmojis().compactMap { emoji -> String? in
      let preferredEmoji = preferredSkinTone.applying(to: emoji)
      return seenReactions.insert(preferredEmoji).inserted ? preferredEmoji : nil
    }
    let reactions = ReactionPickerEmojis.prioritizingMessageEmojis(
      in: fullMessage.message.text,
      among: usualReactions
    )

    let preferredWidth = ContextMenuAccessoryLayout.reactionPickerWidth(for: containerWidth())

    let containerView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.backgroundColor = .clear

    let containerHeight: CGFloat
    let horizontalGlassInset: CGFloat
    let verticalGlassInset: CGFloat
    if #available(iOS 26.0, *) {
      containerHeight = ContextMenuAccessoryLayout.accessoryHostHeight
      horizontalGlassInset = 0
      verticalGlassInset = (ContextMenuAccessoryLayout.accessoryHostHeight - ContextMenuAccessoryLayout
        .reactionPickerHeight) / 2
    } else {
      containerHeight = ContextMenuAccessoryLayout.reactionPickerHeight
      horizontalGlassInset = 0
      verticalGlassInset = 0
    }

    let effectView: UIVisualEffectView
    if #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect(style: .regular)
      glassEffect.isInteractive = true
      effectView = UIVisualEffectView(effect: glassEffect)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    }
    effectView.translatesAutoresizingMaskIntoConstraints = false
    effectView.layer.cornerRadius = ContextMenuAccessoryLayout.reactionPickerHeight / 2
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    containerView.addSubview(effectView)

    let scrollView = ReactionPickerScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = true
    effectView.contentView.addSubview(scrollView)

    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.alignment = .center
    stackView.spacing = 4
    stackView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stackView)

    for reaction in reactions {
      stackView.addArrangedSubview(reactionButton(
        reaction: reaction,
        messageStableId: fullMessage.id,
        messageId: fullMessage.message.messageId,
        chatId: fullMessage.message.chatId,
        randomId: fullMessage.message.randomId
      ))
    }

    // Only the plus stays fixed; learned reactions scroll with the rest, as on macOS.
    let moreButton = UIButton(type: .system)
    moreButton.translatesAutoresizingMaskIntoConstraints = false
    var moreConfiguration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      moreConfiguration = .glass()
    } else {
      moreConfiguration = .plain()
      moreConfiguration.background.backgroundColor = .tertiarySystemFill
    }
    moreConfiguration.cornerStyle = .capsule
    moreConfiguration.contentInsets = .zero
    moreConfiguration.image = UIImage(systemName: "plus")
    moreConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
    moreConfiguration.baseForegroundColor = .secondaryLabel
    moreButton.configuration = moreConfiguration
    moreButton.accessibilityLabel = "More reactions"
    moreButton.accessibilityHint = "Opens the emoji picker"
    moreButton.accessibilityIdentifier = "moreReactions"
    moreButton.addAction(UIAction { [weak self] _ in
      self?.showReactionEmojiPicker(for: fullMessage)
    }, for: .touchUpInside)
    // A sibling overlay keeps the native glass deformation outside the capsule's clipping mask.
    containerView.addSubview(moreButton)

    NSLayoutConstraint.activate([
      moreButton.widthAnchor.constraint(equalToConstant: ContextMenuAccessoryLayout.reactionButtonSize),
      moreButton.heightAnchor.constraint(equalToConstant: ContextMenuAccessoryLayout.reactionButtonSize),
      moreButton.trailingAnchor.constraint(
        equalTo: effectView.trailingAnchor, constant: -ContextMenuAccessoryLayout.reactionPickerContentInset
      ),
      moreButton.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
      containerView.widthAnchor.constraint(equalToConstant: preferredWidth),
      containerView.heightAnchor.constraint(equalToConstant: containerHeight),

      effectView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: verticalGlassInset),
      effectView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: horizontalGlassInset),
      effectView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -horizontalGlassInset),
      effectView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -verticalGlassInset),

      scrollView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
      // Run the row's trailing fade under the plus so the two blend; the stack inset
      // below keeps the last reaction clear of the plus at the end of the scroll.
      scrollView.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: 12),
      scrollView.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),

      stackView.topAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.topAnchor,
        constant: ContextMenuAccessoryLayout.reactionPickerContentInset
      ),
      stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 4),
      stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
      stackView.bottomAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.bottomAnchor,
        constant: -ContextMenuAccessoryLayout.reactionPickerContentInset
      ),
      stackView.heightAnchor.constraint(equalToConstant: ContextMenuAccessoryLayout.reactionButtonSize),
    ])

    containerView.clipsToBounds = false
    return containerView
  }

  func showReactionEmojiPicker(for fullMessage: FullMessage) {
    guard reactionPickerPresentation == nil,
          let presenter = presenter(),
          let current = currentMessage(
            fullMessage.id, fullMessage.message.messageId, fullMessage.message.chatId, fullMessage.message.randomId
          )
    else { return }

    let selectedEmojis = Set(current.reactions
      .filter { $0.reaction.userId == Auth.shared.getCurrentUserId() }
      .map(\.reaction.emoji))
    guard #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) else {
      presentLegacyEmojiPicker(for: fullMessage, presenter: presenter)
      return
    }
    let picker = ReactionEmojiPickerSheet(selectedEmojis: selectedEmojis) { [weak self] emoji in
      self?.react(fullMessage.id) { [weak self] in
        self?.toggleReaction(
          emoji,
          messageStableId: fullMessage.id,
          messageId: fullMessage.message.messageId,
          chatId: fullMessage.message.chatId,
          randomId: fullMessage.message.randomId
        )
      }
    }
    // Keep the live menu and preview in place: presenting from the chat would close the menu
    // first and run the two animations one after the other.
    reactionPickerPresentation = ReactionEmojiPickerPresentation(
      picker: picker,
      presenter: presenter,
      over: emojiSheetOverWindow(),
      tintColor: theme.primary.uiColor,
      onDismiss: { [weak self] in
        self?.reactionPickerPresentation = nil
        self?.onEmojiSheetDismissed()
      }
    )
  }

  /// iOS 15–16: the UIKit emoji picker, presented from the chat.
  private func presentLegacyEmojiPicker(for fullMessage: FullMessage, presenter: UIViewController) {
    let picker = MCEmojiPickerViewController()
    let delegate = LegacyEmojiPickerDelegate { [weak self] emoji in
      self?.react(fullMessage.id) { [weak self] in
        self?.toggleReaction(
          emoji,
          messageStableId: fullMessage.id,
          messageId: fullMessage.message.messageId,
          chatId: fullMessage.message.chatId,
          randomId: fullMessage.message.randomId
        )
      }
    }
    picker.delegate = delegate
    objc_setAssociatedObject(picker, &LegacyEmojiPickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    picker.sourceView = presenter.view
    picker.modalPresentationStyle = .pageSheet
    picker.compatConfigureSheet(detents: [.medium, .large])
    presenter.present(picker, animated: true)
    onEmojiSheetDismissed()
  }

  func toggleReaction(_ emoji: String, messageStableId: Int64, messageId: Int64, chatId: Int64, randomId: Int64?) {
    guard let fullMessage = currentMessage(messageStableId, messageId, chatId, randomId) else { return }
    let message = fullMessage.message
    if fullMessage.reactions
      .contains(where: { $0.reaction.emoji == emoji && $0.reaction.userId == Auth.shared.getCurrentUserId() ?? 0 })
    {
      MessageViewActions.sendReactionMutation(.deleteReaction(emoji: emoji, message: message))
    } else {
      MessageViewActions.sendReactionMutation(.addReaction(emoji: emoji, message: message))
      ReactionPickerEmojiUsageStore.recordPick(emoji)
    }
  }

  private func reactionButton(
    reaction: String,
    messageStableId: Int64,
    messageId: Int64,
    chatId: Int64,
    randomId: Int64?
  ) -> UIButton {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false

    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
    configuration.title = reaction
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = .systemFont(ofSize: ContextMenuAccessoryLayout.reactionEmojiPointSize)
      return outgoing
    }
    button.configuration = configuration
    button.accessibilityLabel = reaction
    button.layer.cornerRadius = ContextMenuAccessoryLayout.reactionButtonSize / 2
    button.clipsToBounds = true
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: ContextMenuAccessoryLayout.reactionButtonSize),
      button.heightAnchor.constraint(equalToConstant: ContextMenuAccessoryLayout.reactionButtonSize),
    ])

    button.addAction(UIAction { [weak self, weak button] _ in
      guard let self, let button else { return }
      reactionButtonTouchUp(button)
      react(messageStableId) { [weak self] in
        self?.toggleReaction(
          reaction, messageStableId: messageStableId, messageId: messageId, chatId: chatId, randomId: randomId
        )
      }
    }, for: .touchUpInside)
    button.addTarget(self, action: #selector(reactionButtonTouchDown(_:)), for: .touchDown)
    button.addTarget(
      self,
      action: #selector(reactionButtonTouchUp(_:)),
      for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
    )
    return button
  }

  @objc private func reactionButtonTouchDown(_ sender: UIButton) {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    generator.impactOccurred()
    let tint = theme.primary.uiColor
    let updates = {
      sender.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
      sender.backgroundColor = tint.withAlphaComponent(0.3)
    }
    guard !UIAccessibility.isReduceMotionEnabled else {
      UIView.performWithoutAnimation(updates)
      return
    }
    UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      updates()
    }
  }

  @objc private func reactionButtonTouchUp(_ sender: UIButton) {
    let updates = {
      sender.transform = .identity
      sender.backgroundColor = .clear
    }
    guard !UIAccessibility.isReduceMotionEnabled else {
      UIView.performWithoutAnimation(updates)
      return
    }
    UIView.animate(
      withDuration: 0.16,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.4,
      options: [.allowUserInteraction, .beginFromCurrentState],
      animations: updates
    )
  }

  // MARK: - Actions

  func showDeleteConfirmation(messageId: Int64, peerId: Peer, chatId: Int64) {
    MessageViewActions.confirmDeleteMessage(from: presenter()) {
      MessageViewActions.sendDeleteMessage(messageId: messageId, peerId: peerId, chatId: chatId)
    }
  }

  func showDeleteConfirmationForFailed(messageId: Int64, peerId: Peer, chatId: Int64) {
    guard let viewController = presenter() else { return }
    let alert = UIAlertController(
      title: "Delete Failed Message",
      message: "Are you sure you want to delete this failed message?",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
      Task {
        // Delete locally without server call since it failed to send
        let _ = try? await AppDatabase.shared.dbWriter.write { db in
          try Message.deleteMessages(db, messageIds: [messageId], chatId: chatId)
        }
        await MainActor.run {
          MessagesPublisher.shared.messagesDeleted(messageIds: [messageId], peer: peerId)
        }
      }
    })
    viewController.present(alert, animated: true)
  }

  func resendMessage(_ fullMessage: FullMessage) {
    Task { @MainActor in
      do { try await FailedMessageResender.resend(fullMessage) }
      catch { ToastManager.shared.showToast(error.localizedDescription, type: .error) }
    }
  }

  func togglePinMessage(_ message: Message, unpin: Bool) {
    Task { @MainActor in
      do {
        _ = try await Api.realtime.send(.pinMessage(peer: message.peerId, messageId: message.messageId, unpin: unpin))
      } catch {
        Log.shared.error("Failed to update pinned message", error: error)
      }
    }
  }

  func presentForwardSheet(_ fullMessage: FullMessage) {
    guard let viewController = presenter() else { return }
    guard #available(iOS 17.0, *), CompatRuntime.allows(.iOS17) else {
      ToastManager.shared.showToast(
        "Forwarding needs iOS 17 or later for now", type: .info, systemImage: "arrowshape.turn.up.right"
      )
      return
    }
    let rootView = InlineUI.ForwardMessagesSheet(
      messages: [fullMessage],
      onSelect: { destination, selection in
        let destinationPeer = destination.peerId
        ChatState.shared.setForwardingMessages(
          peer: destinationPeer,
          fromPeerId: selection.fromPeerId,
          sourceChatId: selection.sourceChatId,
          messageIds: selection.messageIds
        )
        var userInfo: [AnyHashable: Any] = [:]
        if let userId = destinationPeer.asUserId() { userInfo["peerUserId"] = userId }
        if let threadId = destinationPeer.asThreadId() { userInfo["peerThreadId"] = threadId }
        NotificationCenter.default.post(
          name: Notification.Name("NavigateToForwardDestination"), object: nil, userInfo: userInfo
        )
      },
      onSend: { destinations, selection in
        await Self.forwardMessages(destinations: destinations, selection: selection)
      }
    )
    .appDatabase(AppDatabase.shared)
    let hostingController = UIHostingController(rootView: rootView)
    hostingController.modalPresentationStyle = .pageSheet
    viewController.present(hostingController, animated: true)
  }

  private static func forwardMessages(
    destinations: [HomeChatItem],
    selection: InlineUI.ForwardMessagesSelection
  ) async {
    guard !destinations.isEmpty else { return }
    guard !selection.messageIds.isEmpty else {
      Log.shared.error("Forward failed: empty message ids")
      return
    }
    for destination in destinations {
      let destinationPeer = destination.peerId
      do {
        let result = try await Api.realtime.send(.forwardMessages(
          fromPeerId: selection.fromPeerId,
          toPeerId: destinationPeer,
          messageIds: selection.messageIds
        ))
        if case let .forwardMessages(response) = result, response.updates.isEmpty {
          _ = await Api.realtime.sendQueued(.getChatHistory(peer: destinationPeer))
        }
      } catch {
        Log.shared.error("Forward failed", error: error)
      }
    }
    ToastManager.shared.showToast(
      "Forwarded to \(destinations.count) chats", type: .success, systemImage: "arrowshape.turn.up.right"
    )
  }

  private func notionTaskAction(for message: Message) -> UIAction? {
    // Only show "Create Notion Task" if user has integration access
    guard NotionTaskManager.shared.hasAccess else { return nil }
    let spaceId = validSpaceId
    return UIAction(title: "Create Notion Task", image: UIImage(systemName: "circle.badge.plus")) { _ in
      Task {
        await NotionTaskManager.shared.handleWillDoAction(for: message, spaceId: spaceId)
      }
    }
  }

  private func linearIssueAction(for message: Message) -> UIAction? {
    guard let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    // Only show in spaces that have Linear connected (avoid showing action in spaces without Linear).
    // For DMs, only show if the user has Linear connected in at least one space.
    if message.peerId.isThread {
      guard hasLinearConnected else { return nil }
      guard let linearTeamId, !linearTeamId.isEmpty else { return nil }
    } else {
      guard hasLinearConnected else { return nil }
    }

    return UIAction(title: "Create Linear Issue", image: UIImage(systemName: "circle.badge.plus")) { _ in
      Task { [weak self] in
        guard let self else { return }
        if message.peerId.isThread {
          guard hasLinearConnected else { return }
          guard let linearTeamId, !linearTeamId.isEmpty else {
            ToastManager.shared.showToast(
              "Select a default Linear team in Space Integrations first.",
              type: .error,
              systemImage: "exclamationmark.triangle"
            )
            return
          }
          await createLinearIssue(text: text, message: message, spaceId: validSpaceId)
          return
        }

        do {
          let integrations = try await InlineRPCClient.shared.integrations(
            userID: Auth.shared.getCurrentUserId() ?? 0,
            spaceID: nil
          )
          guard integrations.hasLinearConnected else {
            ToastManager.shared.showToast(
              "No Linear integration found. Connect Linear in one of your spaces.",
              type: .error,
              systemImage: "exclamationmark.triangle"
            )
            return
          }
          guard let linearSpaces = integrations.linearSpaces, !linearSpaces.isEmpty else {
            ToastManager.shared.showToast(
              "No accessible Linear integrations found", type: .error, systemImage: "exclamationmark.triangle"
            )
            return
          }
          showIntegrationSpaceSelectionSheet(
            title: "Select Space",
            message: "Choose which space to create the Linear issue in:",
            spaces: linearSpaces.map { (id: $0.spaceId, name: $0.spaceName) },
            completion: { selectedSpaceId in
              Task { [weak self] in
                guard let self else { return }
                do {
                  let perSpace = try await InlineRPCClient.shared.integrations(
                    userID: Auth.shared.getCurrentUserId() ?? 0,
                    spaceID: selectedSpaceId
                  )
                  guard perSpace.hasLinearConnected else {
                    ToastManager.shared.showToast(
                      "Linear isn’t connected for that space.", type: .error, systemImage: "exclamationmark.triangle"
                    )
                    return
                  }
                  guard let teamId = perSpace.linearTeamId, !teamId.isEmpty else {
                    ToastManager.shared.showToast(
                      "Select a default Linear team for that space first.",
                      type: .error,
                      systemImage: "exclamationmark.triangle"
                    )
                    return
                  }
                  await createLinearIssue(text: text, message: message, spaceId: selectedSpaceId)
                } catch {
                  ToastManager.shared.showToast(
                    "Failed to fetch integrations for that space", type: .error, systemImage: "exclamationmark.triangle"
                  )
                }
              }
            }
          )
        } catch {
          ToastManager.shared.showToast(
            "Failed to fetch integrations", type: .error, systemImage: "exclamationmark.triangle"
          )
        }
      }
    }
  }

  private func createLinearIssue(text _: String, message: Message, spaceId: Int64?) async {
    ToastManager.shared.showToast(
      "Creating Linear issue…", type: .info, systemImage: "linear-icon", shouldStayVisible: true
    )
    do {
      guard let spaceId else { throw InlineRPCClientError.unexpectedResponse }
      let result = try await InlineRPCClient.shared.createLinearIssue(
        spaceID: spaceId,
        messageID: message.messageId,
        peerID: message.peerId
      )
      guard let link = result.link, let url = URL(string: link) else {
        ToastManager.shared.showToast(
          "Failed to create Linear issue", type: .error, systemImage: "exclamationmark.triangle"
        )
        return
      }
      ToastManager.shared.showToast(
        "Linear issue created",
        type: .success,
        systemImage: "checkmark.circle",
        action: { InAppBrowser.shared.open(url) },
        actionTitle: "Fast Open"
      )
    } catch {
      ToastManager.shared.showToast(
        "Failed to create Linear issue", type: .error, systemImage: "exclamationmark.triangle"
      )
    }
  }

  fileprivate func showIntegrationSpaceSelectionSheet(
    title: String,
    message: String,
    spaces: [(id: Int64, name: String)],
    completion: @escaping @Sendable (Int64) -> Void
  ) {
    guard let viewController = presenter() else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
    for space in spaces {
      alert.addAction(UIAlertAction(title: space.name, style: .default) { _ in completion(space.id) })
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    // For iPad
    if let popover = alert.popoverPresentationController {
      popover.sourceView = viewController.view
      popover.sourceRect = CGRect(x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    viewController.present(alert, animated: true)
  }
}

// MARK: - Notion task progress

extension MessageMenuActions: NotionTaskManagerDelegate {
  nonisolated func showErrorToast(_ message: String, systemImage: String) {
    Task { @MainActor in
      ToastManager.shared.showToast(message, type: .error, systemImage: systemImage)
    }
  }

  nonisolated func showSuccessToast(_ message: String, systemImage: String, url: String) {
    Task { @MainActor in
      ToastManager.shared.showToast(
        message,
        type: .success,
        systemImage: systemImage,
        action: {
          if let url = URL(string: url) { InAppBrowser.shared.open(url) }
        },
        actionTitle: "Fast Open"
      )
    }
  }

  nonisolated func showSpaceSelectionSheet(spaces: [NotionSpace], completion: @escaping @Sendable (Int64) -> Void) {
    let spaces = spaces.map { (id: $0.spaceId, name: $0.spaceName) }
    Task { @MainActor [weak self] in
      self?.showIntegrationSpaceSelectionSheet(
        title: "Select Space",
        message: "Choose which space to create the Notion task in the selected database:",
        spaces: spaces,
        completion: completion
      )
    }
  }

  nonisolated func showProgressStep(_ step: Int, message: String, systemImage: String) {
    Task { @MainActor in
      ToastManager.shared.showProgressStep(step, message: message, systemImage: systemImage)
    }
  }

  nonisolated func updateProgressToast(message: String, systemImage: String) {
    Task { @MainActor in
      ToastManager.shared.updateProgressToast(message: message, systemImage: systemImage)
    }
  }
}

/// Bridges MCEmojiPicker's delegate to a closure.
private final class LegacyEmojiPickerDelegate: NSObject, MCEmojiPickerDelegate {
  nonisolated(unsafe) static var key: UInt8 = 0
  private let onPick: @MainActor (String) -> Void

  init(onPick: @escaping @MainActor (String) -> Void) {
    self.onPick = onPick
  }

  func didGetEmoji(emoji: String) {
    MainActor.assumeIsolated { onPick(emoji) }
  }
}

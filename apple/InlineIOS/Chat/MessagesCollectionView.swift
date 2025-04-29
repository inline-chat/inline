import Auth
import GRDB
import iMessageUI
import InlineKit
import Logger
import Nuke
import NukeUI
import UIKit

final class MessagesCollectionView: UICollectionView {
  private let peerId: Peer
  private var chatId: Int64
  private var spaceId: Int64
  private var coordinator: Coordinator
  var accessoryProvider: ((IndexPath) -> ([Any]))?
  static var contextMenuOpen: Bool = false

  init(peerId: Peer, chatId: Int64, spaceId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    self.spaceId = spaceId
    let layout = MessagesCollectionView.createLayout()
    coordinator = Coordinator(peerId: peerId, chatId: chatId, spaceId: spaceId)

    super.init(frame: .zero, collectionViewLayout: layout)

    setupCollectionView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func contextMenuAccessories(
    for interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration
  ) -> [Any]? {
    guard let indexPath = configuration.identifier as? IndexPath else { return nil }
    return accessoryProvider?(indexPath)
  }

  override func contextMenuStyle(
    for interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration
  ) -> Any? {
    let _UIContextMenuStyle = NSClassFromString("_UIContextMenuStyle") as! NSObject.Type

    let style = _UIContextMenuStyle.perform(NSSelectorFromString("defaultStyle")).takeUnretainedValue() as! NSObject

    let preferredEdgeInsets = UIEdgeInsets(top: 150.0, left: 30.0, bottom: 150.0, right: 30.0)
    style.setValue(preferredEdgeInsets, forKey: "preferredEdgeInsets")

    return style
  }

  private func setupCollectionView() {
    backgroundColor = .clear
    delegate = coordinator
    autoresizingMask = [.flexibleHeight]
    alwaysBounceVertical = true
    register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )

    transform = CGAffineTransform(scaleX: 1, y: -1)
    showsVerticalScrollIndicator = true
    keyboardDismissMode = .interactive

    coordinator.setupDataSource(self)
    setupObservers()

    prefetchDataSource = self

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
  }

  override func didMoveToWindow() {
    updateContentInsets()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    Log.shared.debug("CollectionView deinit")

    Task {
      await ImagePrefetcher.shared.clearCache()
    }
  }

  func scrollToBottom() {
    if !itemsEmpty, shouldScrollToBottom {
      scrollToItem(
        at: IndexPath(item: 0, section: 0),
        at: .top,
        animated: true
      )
    }
  }

  private var composeHeight: CGFloat = ComposeView.minHeight
  private var composeEmbedViewHeight: CGFloat = ComposeEmbedView.height

  public func updateComposeInset(composeHeight: CGFloat) {
    self.composeHeight = composeHeight
    UIView.animate(withDuration: 0.2) {
      self.updateContentInsets()
      if !self.itemsEmpty, self.shouldScrollToBottom {
        self.scrollToItem(
          at: IndexPath(item: 0, section: 0),
          at: .top,
          animated: false
        )
      }
    }
  }

  static let messagesBottomPadding = 6.0
  func updateContentInsets() {
    guard !MessagesCollectionView.contextMenuOpen else {
      print("CONTEXT MENU OPEN IN UPDATECONTENTINSET \(MessagesCollectionView.contextMenuOpen)")
      return
    }
    guard let window else {
      return
    }

    let topContentPadding: CGFloat = 10
    let navBarHeight = (findViewController()?.navigationController?.navigationBar.frame.height ?? 0)
    let isLandscape = UIDevice.current.orientation.isLandscape
    let topSafeArea = isLandscape ? window.safeAreaInsets.left : window.safeAreaInsets.top
    let bottomSafeArea = isLandscape ? window.safeAreaInsets.right : window.safeAreaInsets.bottom
    let totalTopInset = topSafeArea + navBarHeight

    var bottomInset: CGFloat = 0.0

    let chatState = ChatState.shared.getState(peer: peerId)
    let hasEmbed = chatState.replyingMessageId != nil || chatState.editingMessageId != nil

    bottomInset += composeHeight + (ComposeView.textViewVerticalMargin * 2)
    bottomInset += Self.messagesBottomPadding

    if hasEmbed {
      bottomInset += composeEmbedViewHeight
    }
    if isKeyboardVisible {
      bottomInset += keyboardHeight
    } else {
      bottomInset += bottomSafeArea
    }

    contentInsetAdjustmentBehavior = .never
    automaticallyAdjustsScrollIndicatorInsets = false

    scrollIndicatorInsets = UIEdgeInsets(top: bottomInset, left: 0, bottom: totalTopInset, right: 0)
    contentInset = UIEdgeInsets(top: bottomInset, left: 0, bottom: totalTopInset + topContentPadding, right: 0)
    layoutIfNeeded()
  }

  var calculatedThreshold: CGFloat {
    let baseThreshold = ComposeView
      .minHeight - ((ComposeView.textViewVerticalMargin * 2) + (MessagesCollectionView.messagesBottomPadding * 2))
    return isKeyboardVisible ? baseThreshold + keyboardHeight : baseThreshold
  }

  var shouldScrollToBottom: Bool { contentOffset.y < calculatedThreshold }
  var itemsEmpty: Bool { coordinator.messages.isEmpty }

  @objc func orientationDidChange(_ notification: Notification) {
    coordinator.clearSizeCache()
    guard !isKeyboardVisible else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.updateContentInsets()
      UIView.animate(withDuration: 0.3) {
        if self.shouldScrollToBottom, !self.itemsEmpty {
          self.scrollToItem(
            at: IndexPath(item: 0, section: 0),
            at: .top,
            animated: true
          )
        }
      }
    }
  }

  func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        return viewController
      }
      responder = nextResponder
    }
    return nil
  }

  private func setupObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateSetReplyCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateClearReplyCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateSetEditingCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateClearEditingCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillShow),
      name: UIResponder.keyboardWillShowNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillHide),
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScrollToBottom),
      name: .scrollToBottom,
      object: nil
    )
  }

  var isKeyboardVisible: Bool = false
  var keyboardHeight: CGFloat = 0

  @objc private func keyboardWillShow(_ notification: Notification) {
    isKeyboardVisible = true
    guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
          let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
    else {
      return
    }
    let keyboardFrameHeight = keyboardFrame.height
    keyboardHeight = keyboardFrameHeight

    updateContentInsets()
    UIView.animate(withDuration: duration) {
      if self.shouldScrollToBottom, !self.itemsEmpty {
        self.scrollToItem(
          at: IndexPath(item: 0, section: 0),
          at: .top,
          animated: false
        )
      }
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    isKeyboardVisible = false
    keyboardHeight = 0
    guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
      return
    }

    updateContentInsets()
    UIView.animate(withDuration: duration) {
      if self.shouldScrollToBottom, !self.itemsEmpty {
        self.scrollToItem(
          at: IndexPath(item: 0, section: 0),
          at: .top,
          animated: true
        )
      }
    }
  }

  @objc private func replyStateChanged(_ notification: Notification) {
    DispatchQueue.main.async {
      UIView.animate(withDuration: 0.2, delay: 0) {
        self.updateContentInsets()
        if self.shouldScrollToBottom, !self.itemsEmpty {
          self.scrollToItem(
            at: IndexPath(item: 0, section: 0),
            at: .top,
            animated: true
          )
        }
      }
    }
  }

  @objc private func handleScrollToBottom(_ notification: Notification) {
    if itemsEmpty {
      return
    }
    let visibleHeight = bounds.height

    let targetOffsetY = -contentInset.top

    let currentOffsetY = contentOffset.y
    let distanceToScroll = abs(currentOffsetY - targetOffsetY)

    if distanceToScroll > visibleHeight * 3 {
      let intermediateOffsetY = targetOffsetY + (3 * visibleHeight)

      if currentOffsetY > intermediateOffsetY {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setContentOffset(CGPoint(x: 0, y: intermediateOffsetY), animated: false)

        layoutIfNeeded()
        CATransaction.commit()

        animateScrollToBottom(duration: 0.14)

      } else {
        animateScrollToBottom(duration: 0.14)
      }
    } else {
      scrollToItem(
        at: IndexPath(item: 0, section: 0),
        at: .top,
        animated: true
      )
    }
  }

  private func animateScrollToBottom(duration: TimeInterval) {
    if let attributes = layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) {
      let targetOffset = CGPoint(x: 0, y: attributes.frame.minY - contentInset.top)
      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveEaseOut, .allowUserInteraction],
        animations: {
          self.contentOffset = targetOffset
        }
      )
    }
  }

  private static func createLayout() -> UICollectionViewLayout {
    let layout = AnimatedCollectionViewLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.scrollDirection = .vertical
    layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
    return layout
  }
}

// MARK: - UICollectionViewDataSourcePrefetching

extension MessagesCollectionView: UICollectionViewDataSourcePrefetching {
  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    let messagesToPrefetch: [FullMessage] = indexPaths.compactMap { indexPath in
      guard indexPath.item < coordinator.messages.count else { return nil }
      return coordinator.messages[indexPath.item]
    }.filter { $0.photoInfo != nil }

    if !messagesToPrefetch.isEmpty {
      // Dispatch to background to avoid blocking the main thread
      Task.detached(priority: .low) {
        await ImagePrefetcher.shared.prefetchImages(for: messagesToPrefetch)
      }
    }
  }

  func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
    let messagesToCancel: [FullMessage] = indexPaths.compactMap { indexPath in
      guard indexPath.item < coordinator.messages.count else { return nil }
      return coordinator.messages[indexPath.item]
    }.filter { $0.photoInfo != nil }

    if !messagesToCancel.isEmpty {
      Task.detached(priority: .low) {
        await ImagePrefetcher.shared.cancelPrefetching(for: messagesToCancel)
      }
    }
  }
}

// MARK: - Coordinator

private extension MessagesCollectionView {
  class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
    private var currentCollectionView: UICollectionView?
    private let viewModel: MessagesProgressiveViewModel
    private let peerId: Peer
    private let chatId: Int64
    private let spaceId: Int64
    private weak var collectionContextMenu: UIContextMenuInteraction?

    func collectionView(
      _ collectionView: UICollectionView,
      willDisplayContextMenu configuration: UIContextMenuConfiguration,
      animator: UIContextMenuInteractionAnimating?
    ) {
      MessagesCollectionView.contextMenuOpen = true

      if collectionContextMenu == nil,
         let int = collectionView.interactions
         .first(where: { $0 is UIContextMenuInteraction }) as? UIContextMenuInteraction
      {
        collectionContextMenu = int
      }
    }

    func collectionView(
      _ collectionView: UICollectionView,
      willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
      animator: UIContextMenuInteractionAnimating?
    ) {
      MessagesCollectionView.contextMenuOpen = false
    }

    private func dismissContextMenuIfNeeded() {
      collectionContextMenu?.dismissMenu()
    }

    enum Section {
      case main
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, FullMessage.ID>!
    var messages: [FullMessage] { viewModel.messages }

    init(peerId: Peer, chatId: Int64, spaceId: Int64) {
      self.peerId = peerId
      self.chatId = chatId
      self.spaceId = spaceId
      viewModel = MessagesProgressiveViewModel(peer: peerId, reversed: true)

      super.init()

      viewModel.observe { [weak self] update in
        self?.applyUpdate(update)
      }
    }

    func setupDataSource(_ collectionView: UICollectionView) {
      currentCollectionView = collectionView

      setupContextMenuAccessories()

      let cellRegistration = UICollectionView.CellRegistration<
        MessageCollectionViewCell,
        FullMessage.ID
      > { [weak self] cell, indexPath, messageId in
        guard let self, let message = viewModel.messagesByID[messageId] else { return }
        let isFromDifferentSender = isMessageFromDifferentSender(at: indexPath)

        cell.configure(with: message, fromOtherSender: isFromDifferentSender, spaceId: spaceId)
      }

      dataSource = UICollectionViewDiffableDataSource<Section, FullMessage.ID>(
        collectionView: collectionView
      ) { collectionView, indexPath, messageId in
        collectionView.dequeueConfiguredReusableCell(
          using: cellRegistration,
          for: indexPath,
          item: messageId
        )
      }

      // Set initial data after configuring the data source
      setInitialData()
    }

    private func isMessageFromDifferentSender(at indexPath: IndexPath) -> Bool {
      // Ensure we're not accessing beyond array bounds
      guard indexPath.item < messages.count else { return true }

      let currentMessage = messages[indexPath.item]

      // Ensure previous message exists
      guard indexPath.item + 1 < messages.count else { return true }

      let previousMessage = messages[indexPath.item + 1]

      return currentMessage.message.fromId != previousMessage.message.fromId
    }

    private func setInitialData(animated: Bool? = false) {
      var snapshot = NSDiffableDataSourceSnapshot<Section, FullMessage.ID>()

      // Only one section in this collection view, identified by Section.main
      snapshot.appendSections([.main])

      // Get identifiers of all message in our model and add to initial snapshot
      let itemIdentifiers = messages.map(\.id)

      snapshot.appendItems(itemIdentifiers, toSection: .main)

      dataSource.apply(snapshot, animatingDifferences: animated ?? false)
    }

    func applyUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
      switch update {
        case let .added(newMessages, _):
          // get current snapshot and append new items
          var snapshot = dataSource.snapshot()
          let newIds = newMessages.map(\.id)

          let shouldScroll = newMessages.contains {
            $0.message.fromId == Auth.shared.getCurrentUserId()
          }

          if let first = snapshot.itemIdentifiers.first {
            snapshot.insertItems(newIds, beforeItem: first)
          } else {
            snapshot.appendItems(newIds, toSection: .main)
          }

          // Mark as read if we're at bottom or message is from current user
          if shouldScroll {
            updateUnreadIfNeeded()
          }

          UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .curveEaseInOut]) {
            self.dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
              if shouldScroll {
                self?.currentCollectionView?.scrollToItem(
                  at: IndexPath(item: 0, section: 0),
                  at: .top,
                  animated: true
                )
              }
            }
          }

        case let .deleted(ids, _):
          var snapshot = dataSource.snapshot()
          snapshot.deleteItems(ids)
          dataSource.apply(snapshot, animatingDifferences: true)

        case let .updated(newMessages, _, animated):
          var snapshot = dataSource.snapshot()
          let ids = newMessages.map(\.id)
          snapshot.reconfigureItems(ids)
          dataSource.apply(snapshot, animatingDifferences: animated ?? false)

        case let .reload(animated):
          setInitialData(animated: animated)
      }
    }

    func updateUnreadIfNeeded() {
      UnreadManager.shared.readAll(peerId, chatId: chatId)
    }

    private var sizeCache: [FullMessage.ID: CGSize] = [:]
    private let maxCacheSize = 1_000

    func setupContextMenuAccessories() {
      guard let collectionView = currentCollectionView as? MessagesCollectionView else { return }
      collectionView.accessoryProvider = { [weak self] indexPath in

        guard let message = self?.messages[indexPath.item] else { return [] }
        let alignment: UIContextMenuAccessoryAlignment = if message.message.out == true {
          .trailing
        } else {
          .leading
        }

        let verticalSpacing: CGFloat = 6
        let offset = CGPoint(x: 0, y: -verticalSpacing)

        let accessoryView = _UIContextMenuAccessoryViewBuilder.build(with: alignment, offset: offset)
        accessoryView?.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width - 80, height: 70)
        accessoryView?.backgroundColor = .clear

        if let accessoryView {
          let reactionPickerView = self?.createReactionPickerView(for: message.message, at: indexPath)
          if let reactionPickerView {
            accessoryView.addSubview(reactionPickerView)

            reactionPickerView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
              reactionPickerView.centerXAnchor.constraint(equalTo: accessoryView.centerXAnchor),
              reactionPickerView.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
              reactionPickerView.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
              reactionPickerView.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            ])
          }
        }

        guard let accessoryView else { return [] }
        return [accessoryView]
      }
    }

    func createReactionPickerView(for message: Message, at indexPath: IndexPath) -> UIView {
      let reactions = ["🥹", "❤️", "🫡", "👍", "👎", "🆒", "✔️"]

      let containerView = UIView()
      containerView.translatesAutoresizingMaskIntoConstraints = false

      let blurEffect = UIBlurEffect(style: .systemMaterial)
      let blurView = UIVisualEffectView(effect: blurEffect)
      blurView.translatesAutoresizingMaskIntoConstraints = false
      containerView.addSubview(blurView)

      let stackView = UIStackView()
      stackView.axis = .horizontal
      stackView.distribution = .fillEqually
      stackView.spacing = 6
      stackView.translatesAutoresizingMaskIntoConstraints = false
      blurView.contentView.addSubview(stackView)

      for (index, reaction) in reactions.enumerated() {
        let button = createReactionButton(reaction: reaction, messageIndex: indexPath.item, reactionIndex: index)
        stackView.addArrangedSubview(button)
      }

      NSLayoutConstraint.activate([
        blurView.topAnchor.constraint(equalTo: containerView.topAnchor),
        blurView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
        blurView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        blurView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

        stackView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 7),
        stackView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 8),
        stackView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -8),
        stackView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -7),
      ])

      containerView.layer.cornerRadius = 24
      containerView.layer.cornerCurve = .continuous
      containerView.clipsToBounds = true

      return containerView
    }

    private func createReactionButton(reaction: String, messageIndex: Int, reactionIndex: Int) -> UIButton {
      let button = UIButton(type: .system)
      button.translatesAutoresizingMaskIntoConstraints = false

      var configuration = UIButton.Configuration.plain()
      configuration.title = reaction

      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = .systemFont(ofSize: 22)
        return outgoing
      }

      configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
      button.configuration = configuration

      button.tag = messageIndex * 1_000 + reactionIndex

      button.layer.cornerRadius = 19
      button.clipsToBounds = true

      button.addTarget(self, action: #selector(handleReactionButtonTap(_:)), for: .touchUpInside)
      button.addTarget(self, action: #selector(buttonTouchDown(_:)), for: .touchDown)
      button.addTarget(self, action: #selector(buttonTouchUp(_:)), for: [.touchUpOutside, .touchCancel])

      return button
    }

    @objc private func buttonTouchDown(_ sender: UIButton) {
      let generator = UIImpactFeedbackGenerator(style: .light)
      generator.prepare()
      generator.impactOccurred()

      UIView.animate(withDuration: 0.15) {
        sender.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        sender.backgroundColor = ColorManager.shared.reactionItemColor.withAlphaComponent(0.5)
      }
    }

    @objc private func buttonTouchUp(_ sender: UIButton) {
      UIView.animate(withDuration: 0.22) {
        sender.transform = .identity
        sender.backgroundColor = .clear
      }
    }

    @objc private func handleReactionButtonTap(_ sender: UIButton) {
      let fullMessage = messages[sender.tag / 1_000]
      _ = sender.tag / 1_000
      _ = sender.tag % 1_000
      let message = fullMessage.message

      guard let emoji = sender.configuration?.title else { return }

      buttonTouchUp(sender)
      MessagesCollectionView.contextMenuOpen = false
      dismissContextMenuIfNeeded()
      if fullMessage.reactions
        .filter({ $0.emoji == emoji && $0.userId == Auth.shared.getCurrentUserId() ?? 0 }).first != nil
      {
        Transactions.shared.mutate(transaction: .deleteReaction(.init(
          message: message,
          emoji: emoji,
          peerId: message.peerId,
          chatId: message.chatId
        )))
      } else {
        Transactions.shared.mutate(transaction: .addReaction(.init(
          message: message,
          emoji: emoji,
          userId: Auth.shared.getCurrentUserId() ?? 0,
          peerId: message.peerId
        )))
      }
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
      guard indexPath.item < messages.count else {
        return .zero
      }

      let message = messages[indexPath.item]

      if let cachedSize = sizeCache[message.id] {
        return cachedSize
      }

      let availableWidth = collectionView.bounds.width - 16
      let textWidth = availableWidth - 32

      let font = UIFont.preferredFont(forTextStyle: .body)
      let text = message.message.text ?? ""

      let textHeight = (text as NSString).boundingRect(
        with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
      ).height

      let size = CGSize(width: availableWidth, height: ceil(textHeight) + 24)

      if sizeCache.count >= maxCacheSize {
        // Instead of clearing all, remove oldest entries
        let keysToRemove = Array(sizeCache.keys.prefix(sizeCache.count / 2))
        for key in keysToRemove {
          sizeCache.removeValue(forKey: key)
        }
      }
      sizeCache[message.id] = size

      return size
    }

    func clearSizeCache() {
      sizeCache.removeAll(keepingCapacity: true)
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
      0
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      insetForSectionAt section: Int
    ) -> UIEdgeInsets {
      .zero
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
      0
    }

    func collectionView(
      _ collectionView: UICollectionView,
      contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
      point: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard let indexPath = indexPaths.first else { return nil }
      let fullMessage = messages[indexPath.item]
      let message = fullMessage.message
      let cell = currentCollectionView?.cellForItem(at: indexPath) as! MessageCollectionViewCell

      return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { [weak self] _ in
        guard let self else { return UIMenu(children: []) }

        let isMessageSending = message.status == .sending

        let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "square.on.square")) { _ in
          UIPasteboard.general.string = message.text
        }

        if isMessageSending {
          let cancelAction = UIAction(title: "Cancel", attributes: .destructive) { [weak self] _ in

            if let transactionId = message.transactionId, !transactionId.isEmpty {
              Log.shared.debug("Canceling message with transaction ID: \(transactionId)")

              Transactions.shared.cancel(transactionId: transactionId)
              Task {
                let _ = try? await AppDatabase.shared.dbWriter.write { db in
                  try Message
                    .filter(Column("chatId") == message.chatId)
                    .filter(Column("messageId") == message.messageId)
                    .deleteAll(db)
                }

                MessagesPublisher.shared
                  .messagesDeleted(messageIds: [message.messageId], peer: message.peerId)
              }
            }
          }
          return UIMenu(children: [copyAction, cancelAction])
        }
        var actions: [UIAction] = [copyAction]

        if fullMessage.photoInfo != nil {
          let copyPhotoAction = UIAction(title: "Copy Photo", image: UIImage(systemName: "photo.fill.on.rectangle")) {
            [weak self] _ in
            guard let self else { return }
            if let image = cell.messageView?.newPhotoView.getCurrentImage() {
              UIPasteboard.general.image = image
              ToastManager.shared.showToast(
                "Photo copied to clipboard",
                type: .success,
                systemImage: "doc.on.clipboard"
              )
            }
          }
          actions.append(copyPhotoAction)
        }

        let replyAction = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
          ChatState.shared.setReplyingMessageId(peer: message.peerId, id: message.messageId)
        }
        actions.append(replyAction)

        if message.fromId == Auth.shared.getCurrentUserId() ?? 0, message.hasText {
          let editAction = UIAction(title: "Edit", image: UIImage(systemName: "bubble.and.pencil")) { _ in
            ChatState.shared.setEditingMessageId(peer: message.peerId, id: message.messageId)
          }
          actions.append(editAction)
        }

        // TODO: Add open link

        let deleteAction = UIAction(
          title: "Delete",
          image: UIImage(systemName: "trash"),
          attributes: .destructive
        ) { _ in

          self.showDeleteConfirmation(
            messageId: message.messageId,
            peerId: message.peerId,
            chatId: message.chatId
          )
        }

        actions.append(deleteAction)

        return UIMenu(children: actions)
      }
    }

    func showDeleteConfirmation(messageId: Int64, peerId: Peer, chatId: Int64) {
      // TODO: we have duplicate code here 2 findViewController func
      func findViewController(from view: UIView?) -> UIViewController? {
        guard let view else { return nil }

        var responder: UIResponder? = view
        while let nextResponder = responder?.next {
          if let viewController = nextResponder as? UIViewController {
            return viewController
          }
          responder = nextResponder
        }
        return nil
      }

      guard let viewController = findViewController(from: currentCollectionView) else { return }

      let alert = UIAlertController(
        title: "Delete Message",
        message: "Are you sure you want to delete this message?",
        preferredStyle: .alert
      )

      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

      alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
        guard let self else { return }
        Task {
          let _ = Transactions.shared.mutate(
            transaction: .deleteMessage(
              .init(
                messageIds: [messageId],
                peerId: peerId,
                chatId: chatId
              )
            )
          )
        }
      })

      viewController.present(alert, animated: true)
    }

    // MARK: - UICollectionView

    func collectionView(
      _ collectionView: UICollectionView,
      contextMenuConfiguration configuration: UIContextMenuConfiguration,
      highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
      targetedPreview(for: indexPath)
    }

    func collectionView(
      _ collectionView: UICollectionView,
      contextMenuConfiguration configuration: UIContextMenuConfiguration,
      dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
      targetedPreview(for: indexPath)
    }

    // MARK: - Private

    private func targetedPreview(for indexPath: IndexPath) -> UITargetedPreview? {
      guard let collectionView = currentCollectionView,
            let cell = collectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell,
            let messageView = cell.messageView?.bubbleView else { return nil }

      let parameters = UIPreviewParameters()

      let targetedPreview = UITargetedPreview(view: messageView, parameters: parameters)
      return targetedPreview
    }

    private var isUserDragging = false
    private var isUserScrollInEffect = false
    private var wasPreviouslyAtBottom = false

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      isUserDragging = true
      isUserScrollInEffect = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      isUserDragging = false
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      isUserScrollInEffect = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      /// Reminder: textViewVerticalMargin in ComposeView affects scrollView.contentOffset.y number
      /// (textViewVerticalMargin = 7.0  -> contentOffset.y = -64.0 | textViewVerticalMargin = 4.0 -> contentOffset.y =
      /// -58.0)

      guard let messagesCollectionView = currentCollectionView as? MessagesCollectionView else { return }

      let threshold = messagesCollectionView.calculatedThreshold
      let isAtBottom = scrollView.contentOffset.y > -threshold

      if isAtBottom != wasPreviouslyAtBottom, messages.count > 12 {
        NotificationCenter.default.post(
          name: .scrollToBottomChanged,
          object: nil,
          userInfo: ["isAtBottom": isAtBottom]
        )
        wasPreviouslyAtBottom = isAtBottom
      }
      if isUserScrollInEffect {
        let isAtBottom = scrollView.contentOffset.y >= (scrollView.contentSize.height - scrollView.bounds.size.height)

        if isAtBottom {
          viewModel.loadBatch(at: .older)
          updateItems()
        }
      }
    }

    func updateItems() {
      let currentSnapshot = dataSource.snapshot()
      let currentIds = Set(currentSnapshot.itemIdentifiers)
      let availableIds = Set(messages.map(\.id))
      let missingIds = availableIds.subtracting(currentIds)

      if !missingIds.isEmpty {
        var snapshot = NSDiffableDataSourceSnapshot<Section, FullMessage.ID>()
        snapshot.appendSections([.main])

        let orderedIds = messages.map(\.id)

        snapshot.appendItems(orderedIds, toSection: .main)

        dataSource.apply(snapshot, animatingDifferences: false)
      }
    }
  }
}

final class AnimatedCollectionViewLayout: UICollectionViewFlowLayout {
  override func prepare() {
    super.prepare()

    guard let collectionView else { return }

    // Calculate the available width
    let availableWidth = collectionView.bounds.width - sectionInset.left - sectionInset.right

    // Don't set a fixed itemSize here since we're using automatic sizing
    estimatedItemSize = CGSize(width: availableWidth, height: 1)
  }

  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    guard
      let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)?.copy()
      as? UICollectionViewLayoutAttributes
    else {
      return nil
    }

    attributes.transform = CGAffineTransform(translationX: 0, y: -30)
    return attributes
  }
}

extension Notification.Name {
  static let scrollToBottomChanged = Notification.Name("scrollToBottomChanged")
}

import Auth
import Combine
import GRDB
import InlineKit
import Logger
import Nuke
import NukeUI
import Photos
import UIKit

final class MessagesCollectionView: UICollectionView {
  private let peerId: Peer
  private var chatId: Int64
  private var spaceId: Int64
  private var coordinator: Coordinator

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

  private func setupCollectionView() {
    backgroundColor = .clear
    delegate = coordinator
    autoresizingMask = [.flexibleHeight]
    alwaysBounceVertical = true

    if #available(iOS 26.0, *) {
      topEdgeEffect.isHidden = true
    } else {}

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
      object: nil,
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
    guard let window else {
      return
    }

    let topContentPadding: CGFloat = 10
    let navBarHeight = (findViewController()?.navigationController?.navigationBar.frame.height ?? 0)

    let isLandscape = UIDevice.current.orientation.isLandscape

    // let topSafeArea = isLandscape ? window.safeAreaInsets.left : window.safeAreaInsets.top
    let topSafeArea = isLandscape ? window.safeAreaInsets.top : window.safeAreaInsets.top
//    let bottomSafeArea = isLandscape ? window.safeAreaInsets.right : window.safeAreaInsets.bottom
    let bottomSafeArea = isLandscape ? window.safeAreaInsets.bottom : window.safeAreaInsets.bottom
    let totalTopInset = topSafeArea + navBarHeight

    NotificationCenter.default.post(
      name: Notification.Name("NavigationBarHeight"),
      object: nil,
      userInfo: [
        "navBarHeight": totalTopInset,
      ]
    )

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
//    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    DispatchQueue.main.async {
      UIView.animate(withDuration: 0.3) {
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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScrollToRepliedMessage(_:)),
      name: Notification.Name("ScrollToRepliedMessage"),
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

  // TODO: Handle far reply scroll
  // TODO: Add ensure message
  @objc private func handleScrollToRepliedMessage(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let repliedToMessageId = userInfo["repliedToMessageId"] as? Int64,
          let chatId = userInfo["chatId"] as? Int64,
          chatId == self.chatId else { return }
    // Find the index of the message with this messageId
    if let index = coordinator.messages.firstIndex(where: { $0.message.messageId == repliedToMessageId }) {
      let indexPath = IndexPath(item: index, section: 0)
      scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
      // Highlight the cell after scrolling
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        guard let self else { return }
        // Clear highlight on all visible cells first
        for cell in visibleCells {
          if let cell = cell as? MessageCollectionViewCell {
            cell.clearHighlight()
          }
        }
        if let cell = cellForItem(at: indexPath) as? MessageCollectionViewCell {
          cell.highlightBubble()
        }
      }
    }
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
    private var cancellables = Set<AnyCancellable>()
    private var updateWorkItem: DispatchWorkItem?
    private var isApplyingSnapshot = false
    private var needsAnotherUpdate = false

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
      if gesture.state == .began {
        guard let cell = gesture.view as? MessageCollectionViewCell,
              let message = cell.message else { return }

        ContextMenuManager.shared.show(for: gesture, message: message, spaceId: spaceId)
      }
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

      // Subscribe to translation state changes
      TranslationState.shared.subject
        .sink { [weak self] peer, _ in
          print("👽 TranslationState update")

          guard let self, peer == self.peerId else { return }
          var snapshot = dataSource.snapshot()
          let ids = messages.map(\.id)
          snapshot.reconfigureItems(ids)
          dataSource.apply(snapshot, animatingDifferences: true)
        }
        .store(in: &cancellables)

      // Setup NotionTaskManager delegate
      setupNotionTaskManager()
    }

    private func setupNotionTaskManager() {
      NotionTaskManager.shared.delegate = self
      Task {
        await NotionTaskManager.shared.checkIntegrationAccess(peerId: peerId, spaceId: spaceId)
      }
    }

    func setupDataSource(_ collectionView: UICollectionView) {
      currentCollectionView = collectionView

      let cellRegistration = UICollectionView.CellRegistration<
        MessageCollectionViewCell,
        FullMessage.ID
      > { [weak self] cell, indexPath, messageId in
        guard let self, let message = viewModel.messagesByID[messageId] else { return }
        let isFromDifferentSender = isMessageFromDifferentSender(at: indexPath)

        cell.configure(
          with: message,
          fromOtherSender: isFromDifferentSender,
          spaceId: spaceId
        )

        // Add long press gesture to the cell
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        cell.addGestureRecognizer(longPressGesture)
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

      // Reconfigure all items to ensure cells are reloaded
      snapshot.reconfigureItems(itemIdentifiers)

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

          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }

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
          scheduleUpdateItems()
        }
      }
    }

    func scheduleUpdateItems() {
      updateItemsSafely()
    }

    private func updateItemsSafely() {
      guard !isApplyingSnapshot else {
        needsAnotherUpdate = true
        return
      }
      isApplyingSnapshot = true
      let currentSnapshot = dataSource.snapshot()
      let currentIds = Set(currentSnapshot.itemIdentifiers)
      let availableIds = Set(messages.map(\.id))
      let missingIds = availableIds.subtracting(currentIds)

      if !missingIds.isEmpty {
        var snapshot = NSDiffableDataSourceSnapshot<Section, FullMessage.ID>()
        snapshot.appendSections([.main])
        let orderedIds = messages.map(\.id)
        snapshot.appendItems(orderedIds, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
          guard let self else { return }
          isApplyingSnapshot = false
          if needsAnotherUpdate {
            needsAnotherUpdate = false
            DispatchQueue.main.async { [weak self] in
              self?.scheduleUpdateItems()
            }
          }
        }
      } else {
        isApplyingSnapshot = false
        if needsAnotherUpdate {
          needsAnotherUpdate = false
          DispatchQueue.main.async { [weak self] in
            self?.scheduleUpdateItems()
          }
        }
      }
    }

    private func getMessagesWindow(around targetMessageId: Int64) -> [Int64] {
      guard let targetIndex = messages.firstIndex(where: { $0.message.messageId == targetMessageId }) else {
        return []
      }

      let startIndex = max(0, targetIndex - 50)
      let endIndex = min(messages.count - 1, targetIndex + 50)

      return messages[startIndex ... endIndex].map(\.message.messageId)
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

// MARK: - NotionTaskManagerDelegate Extension

extension MessagesCollectionView.Coordinator: InlineKit.NotionTaskManagerDelegate {
  func showErrorToast(_ message: String, systemImage: String) {
    DispatchQueue.main.async {
      ToastManager.shared.showToast(
        message,
        type: .error,
        systemImage: systemImage
      )
    }
  }

  func showSuccessToast(_ message: String, systemImage: String, url: String) {
    DispatchQueue.main.async {
      ToastManager.shared.showToast(
        message,
        type: .success,
        systemImage: systemImage,
        action: {
          if let url = URL(string: url) {
            UIApplication.shared.open(url)
          }
        },
        actionTitle: "Open"
      )
    }
  }

  func showSpaceSelectionSheet(spaces: [InlineKit.NotionSpace], completion: @escaping @Sendable (Int64) -> Void) {
    // Ensure UI operations happen on the main thread
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }

      // Find the view controller by traversing the responder chain from the collection view
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
        title: "Select Space",
        message: "Choose which space to create the Notion task in the selected database:",
        preferredStyle: .actionSheet
      )

      for space in spaces {
        let action = UIAlertAction(title: space.spaceName, style: .default) { _ in
          completion(space.spaceId)
        }
        alert.addAction(action)
      }

      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

      // For iPad
      if let popover = alert.popoverPresentationController {
        popover.sourceView = viewController.view
        popover.sourceRect = CGRect(
          x: viewController.view.bounds.midX,
          y: viewController.view.bounds.midY,
          width: 0,
          height: 0
        )
        popover.permittedArrowDirections = []
      }

      viewController.present(alert, animated: true)
    }
  }

  func showProgressStep(_ step: Int, message: String, systemImage: String) {
    DispatchQueue.main.async {
      ToastManager.shared.showProgressStep(
        step,
        message: message,
        systemImage: systemImage
      )
    }
  }

  func updateProgressToast(message: String, systemImage: String) {
    DispatchQueue.main.async {
      ToastManager.shared.updateProgressToast(
        message: message,
        systemImage: systemImage
      )
    }
  }
}

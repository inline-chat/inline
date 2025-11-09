import Auth
import Combine
import ContextMenuAccessoryStructs
import GRDB
import InlineKit
import Logger
import Nuke
import NukeUI
import Photos
import Translation
import UIKit

final class MessagesCollectionView: UICollectionView {
  private let peerId: Peer
  private var chatId: Int64
  private var spaceId: Int64
  private var coordinator: Coordinator
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

  private func setupCollectionView() {
    backgroundColor = .clear
    UIContextMenuInteraction.swizzle_delegate_getAccessoryViewsForConfigurationIfNeeded()
    delegate = coordinator
    autoresizingMask = [.flexibleHeight]
    alwaysBounceVertical = true

    if #available(iOS 26.0, *) {
      topEdgeEffect.isHidden = true
      bottomEdgeEffect.isHidden = true
    } else {}

    register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )

    register(
      DateSeparatorView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
      withReuseIdentifier: DateSeparatorView.reuseIdentifier
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
      safeScrollToTop(animated: true)
    }
  }

  private var composeHeight: CGFloat = ComposeView.minHeight
  private var composeEmbedViewHeight: CGFloat = ComposeEmbedView.height

  func updateComposeInset(composeHeight: CGFloat) {
    self.composeHeight = composeHeight
    UIView.animate(withDuration: 0.2) {
      self.updateContentInsets()
      if !self.itemsEmpty, self.shouldScrollToBottom {
        self.safeScrollToTop(animated: false)
      }
    }
  }

  static let messagesBottomPadding = 12.0
  func updateContentInsets() {
    guard !MessagesCollectionView.contextMenuOpen else {
      return
    }
    guard let window else {
      return
    }

    // let topContentPadding: CGFloat = 10
    let topContentPadding: CGFloat = -10
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

  private func findIndexPath(for messageId: Int64) -> IndexPath? {
    for (sectionIndex, section) in coordinator.viewModel.sections.enumerated() {
      for (itemIndex, message) in section.messages.enumerated() {
        if message.message.messageId == messageId {
          let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
          // Validate the index path before returning
          if isValidIndexPath(indexPath) {
            return indexPath
          }
        }
      }
    }
    return nil
  }

  private func isValidIndexPath(_ indexPath: IndexPath) -> Bool {
    // Check both view model and collection view data source to avoid race conditions
    guard indexPath.section >= 0,
          indexPath.section < coordinator.viewModel.numberOfSections(),
          indexPath.item >= 0,
          indexPath.item < coordinator.viewModel.numberOfItems(in: indexPath.section),
          indexPath.section < numberOfSections,
          indexPath.item < numberOfItems(inSection: indexPath.section)
    else {
      return false
    }
    return true
  }

  private func safeScrollToTop(animated: Bool = true) {
    // Check both view model and data source to avoid race conditions
    guard coordinator.viewModel.numberOfSections() > 0,
          coordinator.viewModel.numberOfItems(in: 0) > 0,
          numberOfSections > 0,
          numberOfItems(inSection: 0) > 0
    else {
      return
    }

    let indexPath = IndexPath(item: 0, section: 0)
    scrollToItem(at: indexPath, at: .top, animated: animated)
  }

  @objc func orientationDidChange(_ notification: Notification) {
    coordinator.clearSizeCache()
    guard !isKeyboardVisible else { return }
//    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    DispatchQueue.main.async {
      UIView.animate(withDuration: 0.3) {
        self.updateContentInsets()
        if self.shouldScrollToBottom, !self.itemsEmpty {
          self.safeScrollToTop(animated: true)
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
        self.safeScrollToTop(animated: false)
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
        self.safeScrollToTop(animated: true)
      }
    }
  }

  @objc private func replyStateChanged(_ notification: Notification) {
    DispatchQueue.main.async {
      UIView.animate(withDuration: 0.2, delay: 0) {
        self.updateContentInsets()
        if self.shouldScrollToBottom, !self.itemsEmpty {
          self.safeScrollToTop(animated: true)
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
      safeScrollToTop(animated: true)
    }
  }

  private func animateScrollToBottom(duration: TimeInterval) {
    // Check both view model and data source to avoid race conditions
    guard coordinator.viewModel.numberOfSections() > 0,
          coordinator.viewModel.numberOfItems(in: 0) > 0,
          numberOfSections > 0,
          numberOfItems(inSection: 0) > 0 else { return }

    let indexPath = IndexPath(item: 0, section: 0)
    if let attributes = layoutAttributesForItem(at: indexPath) {
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
    AnimatedCompositionalLayout.createSectionedLayout()
  }

  // TODO: Handle far reply scroll
  // TODO: Add ensure message
  @objc private func handleScrollToRepliedMessage(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let repliedToMessageId = userInfo["repliedToMessageId"] as? Int64,
          let chatId = userInfo["chatId"] as? Int64,
          chatId == self.chatId else { return }
    // Find the index path of the message with this messageId
    if let indexPath = findIndexPath(for: repliedToMessageId), isValidIndexPath(indexPath) {
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
        // Revalidate index path before accessing cell
        if isValidIndexPath(indexPath), let cell = cellForItem(at: indexPath) as? MessageCollectionViewCell {
          cell.highlightBubble()
        }
      }
    }
  }
}

// MARK: - UICollectionViewDataSourcePrefetching

extension MessagesCollectionView: UICollectionViewDataSourcePrefetching {
  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    // Get messages on main actor, then move heavy work to background
    let messagesToPrefetch: [FullMessage] = indexPaths.compactMap { indexPath in
      coordinator.viewModel.message(at: indexPath)
    }.filter { $0.photoInfo != nil }

    if !messagesToPrefetch.isEmpty {
      // Move only the image prefetching to background thread
      Task.detached(priority: .utility) {
        await ImagePrefetcher.shared.prefetchImages(for: messagesToPrefetch)
      }
    }
  }

  func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
    // Get messages on main actor, then move heavy work to background
    let messagesToCancel: [FullMessage] = indexPaths.compactMap { indexPath in
      coordinator.viewModel.message(at: indexPath)
    }.filter { $0.photoInfo != nil }

    if !messagesToCancel.isEmpty {
      // Move only the cancel prefetching to background thread
      Task.detached(priority: .utility) {
        await ImagePrefetcher.shared.cancelPrefetching(for: messagesToCancel)
      }
    }
  }

  @objc func _contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    styleForMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> Any? {
    guard let window = window else { return nil }

    let navBarHeight = (findViewController()?.navigationController?.navigationBar.frame.height ?? 0)
    let topSafeArea = window.safeAreaInsets.top
    let totalTopInset = topSafeArea + navBarHeight

    let styleClass = NSClassFromString("_UIContextMenuStyle") as? NSObject.Type
    guard let style = styleClass?.perform(NSSelectorFromString("defaultStyle"))?.takeUnretainedValue() as? NSObject else {
      return nil
    }

    style.setValue(
      UIEdgeInsets(top: totalTopInset, left: 30, bottom: 0, right: 30),
      forKey: "preferredEdgeInsets"
    )

    return style
  }
}

// MARK: - Coordinator

private extension MessagesCollectionView {
  class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
    private var currentCollectionView: UICollectionView?
    let viewModel: MessagesSectionedViewModel
    private let translationViewModel: TranslationViewModel
    private var hasAnalyzedInitialMessages = false
    private let peerId: Peer
    private let chatId: Int64
    private let spaceId: Int64
    private weak var collectionContextMenu: UIContextMenuInteraction?
    private var cancellables = Set<AnyCancellable>()
    private var updateWorkItem: DispatchWorkItem?

    // MARK: - Date Separator Visibility Handling

    fileprivate var dateSeparatorHideWorkItem: DispatchWorkItem?
    /// Delay before the pinned date badge is hidden after scrolling stops.
    /// Adjust this value to tweak the UX (similar to WhatsApp/Telegram/Signal).
    fileprivate let dateSeparatorHideDelay: TimeInterval = 0.5

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

      if let identifierView = configuration.identifier as? ContextMenuIdentifierUIView {
        identifierView.removeFromSuperview()
      }
    }

    private func dismissContextMenuIfNeeded() {
      collectionContextMenu?.dismissMenu()
    }

    private var dataSource: UICollectionViewDiffableDataSource<Date, FullMessage.ID>!
    var messages: [FullMessage] {
      viewModel.sections.flatMap(\.messages)
    }

    init(peerId: Peer, chatId: Int64, spaceId: Int64) {
      self.peerId = peerId
      self.chatId = chatId
      self.spaceId = spaceId
      viewModel = MessagesSectionedViewModel(peer: peerId, reversed: true)
      translationViewModel = TranslationViewModel(peerId: peerId)

      super.init()

      viewModel.observe { [weak self] update in
        self?.applyUpdate(update)
        self?.handleTranslationForUpdate(update)
      }

      // Subscribe to translation state changes
      TranslationState.shared.subject
        .sink { [weak self] peer, _ in
          print("👽 TranslationState update")

          guard let self, peer == self.peerId else { return }
          var snapshot = dataSource.snapshot()
          let ids = messages.map(\.id)
          // Safety check: only reconfigure items that actually exist in the snapshot
          let existingIds = ids.filter { snapshot.itemIdentifiers.contains($0) }
          if !existingIds.isEmpty {
            snapshot.reconfigureItems(existingIds)
            safeApplySnapshot(snapshot, animatingDifferences: true)
          }
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

        cell.onUserTap = { [weak self] userId in
          guard let self else { return }
          // Navigate to user chat using notification center to bridge back to SwiftUI
          NotificationCenter.default.post(
            name: Notification.Name("NavigateToUser"),
            object: nil,
            userInfo: ["userId": userId]
          )
        }
      }

      dataSource = UICollectionViewDiffableDataSource<Date, FullMessage.ID>(
        collectionView: collectionView
      ) { collectionView, indexPath, messageId in
        collectionView.dequeueConfiguredReusableCell(
          using: cellRegistration,
          for: indexPath,
          item: messageId
        )
      }

      // Configure supplementary view provider for date separators
      dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
        guard let self else { return nil }

        if kind == UICollectionView.elementKindSectionFooter {
          guard let footerView = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: DateSeparatorView.reuseIdentifier,
            for: indexPath
          ) as? DateSeparatorView else {
            return nil
          }

          // Safely get section with bounds checking
          if let section = viewModel.section(at: indexPath.section) {
            footerView.configure(with: section.dayString)
          } else {
            // Fallback for invalid section
            footerView.configure(with: "")
          }

          return footerView
        }

        return nil
      }

      // Set initial data after configuring the data source
      setInitialData()
    }

    private func isMessageFromDifferentSender(at indexPath: IndexPath) -> Bool {
      guard let currentMessage = viewModel.message(at: indexPath) else { return true }

      // Check previous message within the same section
      let previousIndexPath = IndexPath(item: indexPath.item + 1, section: indexPath.section)

      // Ensure the previous index path is valid before checking
      if previousIndexPath.item < viewModel.numberOfItems(in: indexPath.section),
         let previousMessage = viewModel.message(at: previousIndexPath)
      {
        return currentMessage.message.fromId != previousMessage.message.fromId
      }

      // If no previous message in this section, check last message of previous section
      if indexPath.section > 0 {
        let previousSection = indexPath.section - 1
        let previousSectionItemCount = viewModel.numberOfItems(in: previousSection)
        if previousSectionItemCount > 0 {
          let lastMessageInPreviousSection = IndexPath(item: 0, section: previousSection)
          if let lastMessage = viewModel.message(at: lastMessageInPreviousSection) {
            return currentMessage.message.fromId != lastMessage.message.fromId
          }
        }
      }

      return true
    }

    private func setInitialData(animated: Bool? = false) {
      var snapshot = NSDiffableDataSourceSnapshot<Date, FullMessage.ID>()

      // Add sections and their messages using dates as stable identifiers
      for section in viewModel.sections {
        snapshot.appendSections([section.date])
        let messageIds = section.messages.map(\.id)
        snapshot.appendItems(messageIds, toSection: section.date)
      }

      safeApplySnapshot(snapshot, animatingDifferences: animated ?? false) { [weak self] in
        // Kick-off the auto-hide timer on first load as well (after layout pass)
        DispatchQueue.main.async {
          self?.scheduleHideDateSeparators()
        }
      }
    }

    private func safeApplySnapshot(
      _ snapshot: NSDiffableDataSourceSnapshot<Date, FullMessage.ID>,
      animatingDifferences: Bool,
      withCustomTiming: Bool = false,
      completion: (() -> Void)? = nil
    ) {
      guard Thread.isMainThread else {
        DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
          self?.safeApplySnapshot(
            snapshot,
            animatingDifferences: animatingDifferences,
            withCustomTiming: withCustomTiming,
            completion: completion
          )
        }
        return
      }

      if withCustomTiming, animatingDifferences {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.33)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0))
      }

      dataSource.apply(snapshot, animatingDifferences: animatingDifferences) {
        completion?()
      }

      if withCustomTiming, animatingDifferences {
        CATransaction.commit()
      }
    }

    func applyUpdate(_ update: MessagesSectionedViewModel.SectionedMessagesChangeSet) {
      switch update {
        case let .reload(animated):
          setInitialData(animated: animated)

        case let .sectionsChanged(sections):
          setInitialData(animated: true)

        case let .messagesAdded(sectionIndex, messageIds):
          var snapshot = dataSource.snapshot()

          // Validate section index
          guard sectionIndex >= 0, sectionIndex < viewModel.numberOfSections() else {
            setInitialData(animated: true)
            return
          }

          // Check if this is the first section (most recent)
          let shouldScroll = sectionIndex == 0

          // Convert section index to date
          guard let section = viewModel.section(at: sectionIndex) else {
            setInitialData(animated: true)
            return
          }
          let sectionDate = section.date

          if let firstItemInSection = snapshot.itemIdentifiers(inSection: sectionDate).first {
            snapshot.insertItems(messageIds, beforeItem: firstItemInSection)
          } else {
            snapshot.appendItems(messageIds, toSection: sectionDate)
          }

          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            updateUnreadIfNeeded()
          }

          safeApplySnapshot(snapshot, animatingDifferences: true, withCustomTiming: true) { [weak self] in
            if shouldScroll {
              if let collectionView = self?.currentCollectionView as? MessagesCollectionView {
                collectionView.safeScrollToTop(animated: true)
              }
            }
          }

        case let .messagesDeleted(_, messageIds):
          var snapshot = dataSource.snapshot()
          snapshot.deleteItems(messageIds)
          safeApplySnapshot(snapshot, animatingDifferences: true)

        case let .messagesUpdated(_, messageIds, animated):
          var snapshot = dataSource.snapshot()
          // Safety check: only reconfigure items that actually exist in the snapshot
          let existingIds = messageIds.filter { snapshot.itemIdentifiers.contains($0) }
          if !existingIds.isEmpty {
            snapshot.reconfigureItems(existingIds)
            safeApplySnapshot(snapshot, animatingDifferences: animated ?? false)
          }

        case .multiSectionUpdate:
          // Multiple sections affected - do a full data reload for simplicity
          setInitialData(animated: true)
      }
    }

    func updateUnreadIfNeeded() {
      UnreadManager.shared.readAll(peerId, chatId: chatId)
    }

    private var sizeCache: [FullMessage.ID: CGSize] = [:]
    private let maxCacheSize = 1_000

    func createReactionPickerView(for message: Message, at indexPath: IndexPath) -> UIView {
      let reactions = ["🥹", "❤️", "🫡", "👍", "👎", "💯", "😂"] // ✔️

      let containerView = UIView()
      containerView.translatesAutoresizingMaskIntoConstraints = true

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
        let button: UIButton
        if reaction == "✔️" || reaction == "✓" {
          button = UIButton(type: .system)
          button.translatesAutoresizingMaskIntoConstraints = false
          let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
          let image = UIImage(systemName: "checkmark", withConfiguration: config)?
            .withTintColor(UIColor(hex: "#2AAC28")!, renderingMode: .alwaysOriginal)
          button.setImage(image, for: .normal)
          // Use message ID for reliable lookup across sectioned data
          let baseTag = Int(message.messageId % Int64(Int.max - 1_000))
          button.tag = baseTag + index
          button.layer.cornerRadius = 19
          button.clipsToBounds = true
          button.addTarget(self, action: #selector(handleReactionButtonTap(_:)), for: .touchUpInside)
          button.addTarget(self, action: #selector(buttonTouchDown(_:)), for: .touchDown)
          button.addTarget(self, action: #selector(buttonTouchUp(_:)), for: [.touchUpOutside, .touchCancel])
        } else {
          button = createReactionButton(reaction: reaction, messageId: message.messageId, reactionIndex: index)
        }
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

    private func createReactionButton(reaction: String, messageId: Int64, reactionIndex: Int) -> UIButton {
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

      // Use message ID for reliable lookup across sectioned data
      // Format: (messageId % safe_range) * 1000 + reactionIndex
      let baseTag = Int(messageId % Int64(Int.max / 10_000)) // Ensure we don't overflow
      button.tag = baseTag * 1_000 + reactionIndex

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
      // Extract message ID from tag (format: (messageId % safe_range) * 1000 + reactionIndex)
      guard sender.tag >= 1_000 else { return }

      let baseTag = sender.tag / 1_000 // Get the base message ID part

      // Find the message by searching through all sections
      var targetMessage: FullMessage?
      for section in viewModel.sections {
        for message in section.messages {
          let messageBaseTag = Int(message.message.messageId % Int64(Int.max / 10_000))
          if messageBaseTag == baseTag {
            targetMessage = message
            break
          }
        }
        if targetMessage != nil { break }
      }

      guard let fullMessage = targetMessage else {
        print("Could not find message for tag: \(sender.tag), baseTag: \(baseTag)")
        return
      }
      let message = fullMessage.message

      guard let emoji = sender.configuration?.title else { return }

      buttonTouchUp(sender)
      MessagesCollectionView.contextMenuOpen = false
      dismissContextMenuIfNeeded()
      if fullMessage.reactions
        .filter({ $0.reaction.emoji == emoji && $0.reaction.userId == Auth.shared.getCurrentUserId() ?? 0 })
        .first != nil
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
      guard let message = viewModel.message(at: indexPath) else {
        return .zero
      }

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
      guard let indexPath = indexPaths.first,
            let fullMessage = viewModel.message(at: indexPath) else { return nil }
      let message = fullMessage.message
      let cell = currentCollectionView?.cellForItem(at: indexPath) as! MessageCollectionViewCell

      // Check if the touch point is within a view that has its own context menu interaction
      if let messageView = cell.messageView {
        let pointInMessageView = collectionView.convert(point, to: messageView)

        // Check if the point is within any subview that has a context menu interaction
        if let hitView = messageView.hitTest(pointInMessageView, with: nil) {
          // Check if the hit view or any of its superviews (up to messageView) has a context menu interaction
          var currentView: UIView? = hitView
          while let view = currentView, view != messageView {
            if view.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
              // Allow the inner view's context menu to handle this
              return nil
            }
            currentView = view.superview
          }
        }
      }

      let reactionPickerView = createReactionPickerView(for: message, at: indexPath)

      let isOutgoing = message.out == true
      let alignment: ContextMenuAccessoryAlignment = isOutgoing ? .trailing : .leading

      let configuration = ContextMenuAccessoryConfiguration(
        location: .below,
        trackingAxis: .vertical,
        attachment: .center,
        alignment: alignment,
        attachmentOffset: -16,
        alignmentOffset: 0,
        gravity: 0
      )

      let identifierView = ContextMenuIdentifierUIView(
        accessoryView: reactionPickerView,
        configuration: configuration
      )

      collectionView.addSubview(identifierView)

      return UIContextMenuConfiguration(identifier: identifierView, previewProvider: nil) { [weak self] _ in
        guard let self else { return UIMenu(children: []) }

        let isMessageSending = message.status == .sending
        let isMessageFailed = message.status == .failed

        var actions: [UIAction] = []

        if message.hasText {
          let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "square.on.square")) { _ in
            UIPasteboard.general.string = message.text
          }
          actions.append(copyAction)
        }

        if isMessageSending {
          if fullMessage.photoInfo != nil {
            let copyPhotoAction = UIAction(title: "Copy Photo", image: UIImage(systemName: "doc.on.clipboard")) {
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

          let cancelAction = UIAction(title: "Cancel", attributes: .destructive) { [weak self] _ in
            if let transactionId = message.transactionId, !transactionId.isEmpty {
              Log.shared.debug("Canceling message with transaction ID: \(transactionId)")

              Transactions.shared.cancel(transactionId: transactionId)
              Task {
                let _ = try? await AppDatabase.shared.dbWriter.write { db in
                  try Message.deleteMessages(db, messageIds: [message.messageId], chatId: message.chatId)
                }

                MessagesPublisher.shared
                  .messagesDeleted(messageIds: [message.messageId], peer: message.peerId)
              }
            }
          }
          actions.append(cancelAction)

          return UIMenu(children: actions)
        }

        if isMessageFailed {
          if fullMessage.photoInfo != nil {
            let copyPhotoAction = UIAction(title: "Copy Photo", image: UIImage(systemName: "doc.on.clipboard")) {
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

          let resendAction = UIAction(title: "Resend", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.resendMessage(fullMessage)
          }
          actions.append(resendAction)

          let deleteAction = UIAction(title: "Delete", attributes: .destructive) { [weak self] _ in
            self?.showDeleteConfirmationForFailed(
              messageId: message.messageId,
              peerId: message.peerId,
              chatId: message.chatId
            )
          }
          actions.append(deleteAction)

          return UIMenu(children: actions)
        }

        if fullMessage.photoInfo != nil {
          let copyPhotoAction = UIAction(title: "Copy Photo", image: UIImage(systemName: "doc.on.clipboard")) {
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

          let savePhotoAction = UIAction(
            title: "Save Photo",
            image: UIImage(systemName: "square.and.arrow.down")
          ) { [weak self] _ in
            guard let self else { return }
            if let image = cell.messageView?.newPhotoView.getCurrentImage() {
              UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
              ToastManager.shared.showToast(
                "Photo saved to Photos Library",
                type: .success,
                systemImage: "photo"
              )
            } else {
              ToastManager.shared.showToast(
                "Failed to save photo",
                type: .error,
                systemImage: "exclamationmark.triangle"
              )
            }
          }
          actions.append(savePhotoAction)
        }

        let replyAction = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
          ChatState.shared.setReplyingMessageId(peer: message.peerId, id: message.messageId)
        }
        actions.append(replyAction)

        var editAction: UIAction?
        if message.fromId == Auth.shared.getCurrentUserId() ?? 0, message.hasText {
          editAction = UIAction(title: "Edit", image: UIImage(systemName: "bubble.and.pencil")) { _ in
            ChatState.shared.setEditingMessageId(peer: message.peerId, id: message.messageId)
          }
        }

        let willDoAction = createWillDoMenu(for: message)

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

        var menuChildren: [UIMenuElement] = []

        var basicActions = actions
        if let editAction {
          basicActions.append(editAction)
        }

        if !basicActions.isEmpty {
          let basicMenu = UIMenu(title: "", options: .displayInline, children: basicActions)
          menuChildren.append(basicMenu)
        }

        if let willDoAction {
          let willDoMenu = UIMenu(title: "", options: .displayInline, children: [willDoAction])
          menuChildren.append(willDoMenu)
        }

        let deleteMenu = UIMenu(title: "", options: .displayInline, children: [deleteAction])
        menuChildren.append(deleteMenu)

        return UIMenu(children: menuChildren)
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

    func showDeleteConfirmationForFailed(messageId: Int64, peerId: Peer, chatId: Int64) {
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
        title: "Delete Failed Message",
        message: "Are you sure you want to delete this failed message?",
        preferredStyle: .alert
      )

      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

      alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
        guard let self else { return }
        Task {
          // Delete locally without server call since it failed to send
          let _ = try? await AppDatabase.shared.dbWriter.write { db in
            try Message.deleteMessages(db, messageIds: [messageId], chatId: chatId)
          }

          await MainActor.run {
            MessagesPublisher.shared
              .messagesDeleted(messageIds: [messageId], peer: peerId)
          }
        }
      })

      viewController.present(alert, animated: true)
    }

    func resendMessage(_ fullMessage: FullMessage) {
      let message = fullMessage.message

      Task {
        // Reconstruct media items from the failed message
        var mediaItems: [FileMediaItem] = []

        // Handle photo
        if let photoInfo = fullMessage.photoInfo {
          let mediaItem = FileMediaItem.photo(photoInfo)
          mediaItems.append(mediaItem)
        }

        // Handle video
        if let videoInfo = fullMessage.videoInfo {
          let mediaItem = FileMediaItem.video(videoInfo)
          mediaItems.append(mediaItem)
        }

        // Handle document
        if let documentInfo = fullMessage.documentInfo {
          let mediaItem = FileMediaItem.document(documentInfo)
          mediaItems.append(mediaItem)
        }

        // Delete the failed message first
        _ = try? await AppDatabase.shared.dbWriter.write { db in
          try Message.deleteMessages(db, messageIds: [message.messageId], chatId: message.chatId)
        }

        await MainActor.run {
          MessagesPublisher.shared
            .messagesDeleted(messageIds: [message.messageId], peer: message.peerId)
        }

        // Send new message with reconstructed data
        if mediaItems.isEmpty {
          // Text-only message
          try await Api.realtime.send(
            .sendMessage(
              text: message.text ?? "",
              peerId: message.peerId,
              chatId: message.chatId,
              replyToMsgId: message.repliedToMessageId, // Preserve original reply
              isSticker: message.isSticker,
              entities: message.entities
            )
          )
        } else {
          // Message with media
          await Transactions.shared.mutate(
            transaction: .sendMessage(.init(
              text: message.text,
              peerId: message.peerId,
              chatId: message.chatId,
              mediaItems: mediaItems,
              replyToMsgId: message.repliedToMessageId, // Preserve original reply
              isSticker: message.isSticker,
              entities: message.entities
            ))
          )
        }
      }
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
      parameters.backgroundColor = messageView.backgroundColor

      let targetedPreview = UITargetedPreview(view: messageView, parameters: parameters)
      return targetedPreview
    }

    private var isUserDragging = false
    private var isUserScrollInEffect = false
    private var wasPreviouslyAtBottom = false

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      isUserDragging = true
      isUserScrollInEffect = true
      // Show date badge immediately when user starts interacting
      dateSeparatorHideWorkItem?.cancel()
      setDateSeparators(hidden: false, animated: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      isUserDragging = false
      if !decelerate {
        scheduleHideDateSeparators()
      }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      isUserScrollInEffect = false
      scheduleHideDateSeparators()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      // Ensure date badge is visible while the user is actively scrolling.
      dateSeparatorHideWorkItem?.cancel()
      setDateSeparators(hidden: false, animated: false)

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
        // For inverted collection view, we need to detect when user scrolls to the "top" (oldest messages)
        // which is actually at the maximum content offset position
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.size.height
        let threshold: CGFloat = 100 // Load when within 100 points of the top

        // Ensure we're within valid content bounds (not overscrolling)
        let isWithinBounds = scrollView.contentOffset.y <= maxOffset
        let isNearTop = scrollView.contentOffset.y >= (maxOffset - threshold)

        if isNearTop, isWithinBounds, maxOffset > 0 {
          viewModel.loadBatch(at: .older)
          scheduleUpdateItems()
        }
      }
    }

    func scheduleUpdateItems() {
      updateItemsSafely()
    }

    private func updateItemsSafely() {
      let currentSnapshot = dataSource.snapshot()
      let currentIds = Set(currentSnapshot.itemIdentifiers)
      let availableIds = Set(messages.map(\.id))
      let missingIds = availableIds.subtracting(currentIds)

      if !missingIds.isEmpty {
        print("missingIds = \(missingIds)")
        setInitialData(animated: false)
      }
    }

    // MARK: - Date Separator Visibility

    private func setDateSeparators(hidden: Bool, animated: Bool) {
      guard let collectionView = currentCollectionView else { return }

      let footers = collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter)
      let targetAlpha: CGFloat = hidden ? 0 : 1

      // The physical bottom edge of the visible rect in the collection-view's coordinate space
      let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.contentInset
        .bottom

      for view in footers {
        guard let separator = view as? DateSeparatorView else { continue }

        // Detect if this footer is currently pinned to the bottom (sticky)
        let isPinned = abs(separator.frame.maxY - visibleBottom) < 1.0
        guard isPinned else { continue }

        if animated {
          UIView.animate(withDuration: 0.2) {
            separator.alpha = targetAlpha
          }
        } else {
          separator.alpha = targetAlpha
        }
      }
    }

    private func scheduleHideDateSeparators() {
      // Cancel any existing scheduled hide operation
      dateSeparatorHideWorkItem?.cancel()

      let workItem = DispatchWorkItem { [weak self] in
        self?.setDateSeparators(hidden: true, animated: true)
      }
      dateSeparatorHideWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + dateSeparatorHideDelay, execute: workItem)
    }

    private func getMessagesWindow(around targetMessageId: Int64) -> [Int64] {
      guard let targetIndex = messages.firstIndex(where: { $0.message.messageId == targetMessageId }) else {
        return []
      }

      let startIndex = max(0, targetIndex - 50)
      let endIndex = min(messages.count - 1, targetIndex + 50)

      return messages[startIndex ... endIndex].map(\.message.messageId)
    }

    private func createWillDoMenu(for message: Message) -> UIAction? {
      // Only show "Will Do" if user has integration access
      guard NotionTaskManager.shared.hasAccess else { return nil }

      return UIAction(
        title: "Will Do",
        image: UIImage(systemName: "circle.badge.plus")
      ) { _ in
        Task {
          await NotionTaskManager.shared.handleWillDoAction(for: message, spaceId: self.spaceId)
        }
      }
    }
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

  // MARK: - Translation Handling

  private func handleTranslationForUpdate(_ update: MessagesSectionedViewModel.SectionedMessagesChangeSet) {
    Task {
      await handleTranslationForUpdateInner(update)
    }
  }

  private func handleTranslationForUpdateInner(_ update: MessagesSectionedViewModel.SectionedMessagesChangeSet) async {
    switch update {
      case .reload:
        // For reload, trigger translation on all current messages
        await translationViewModel.messagesDisplayed(messages: viewModel.messages)

        // Also analyze for translation detection on initial load
        if !hasAnalyzedInitialMessages, !viewModel.messages.isEmpty {
          await TranslationDetector.shared.analyzeMessages(peer: peerId, messages: viewModel.messages)
          hasAnalyzedInitialMessages = true
        }

      case let .messagesAdded(_, messageIds):
        // For added messages, get them from the viewModel and trigger translation
        let addedMessages = messageIds.compactMap { messageId in
          viewModel.messagesByID[messageId]
        }
        if !addedMessages.isEmpty {
          await translationViewModel.messagesDisplayed(messages: addedMessages)

          // Also analyze new messages for translation detection if we haven't done initial analysis
          if !hasAnalyzedInitialMessages {
            await TranslationDetector.shared.analyzeMessages(peer: peerId, messages: addedMessages)
            hasAnalyzedInitialMessages = true
          }
        }

      case let .messagesUpdated(_, messageIds, _):
        // For updated messages, get them from the viewModel and trigger translation
        let updatedMessages = messageIds.compactMap { messageId in
          viewModel.messagesByID[messageId]
        }
        if !updatedMessages.isEmpty {
          await translationViewModel.messagesDisplayed(messages: updatedMessages)
        }

      case .sectionsChanged:
        // For section changes, trigger translation on all current messages
        await translationViewModel.messagesDisplayed(messages: viewModel.messages)

      case let .multiSectionUpdate(sections: sections):
        // For section changes, trigger translation on all current messages
        await translationViewModel.messagesDisplayed(messages: viewModel.messages)

      case .messagesDeleted:
        // No action needed for deletes
        break
    }
  }
}

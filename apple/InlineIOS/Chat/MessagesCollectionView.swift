import InlineKit
import Nuke
import NukeUI
import UIKit

class MessagesCollectionView: UICollectionView {
  private let peerId: Peer
  private var coordinator: Coordinator
  private var imagePrefetchDataSource: ImagePrefetchDataSource?

  init(peerId: Peer) {
    self.peerId = peerId
    let layout = MessagesCollectionView.createLayout()
    coordinator = Coordinator(peerId: peerId)

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

    register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )

    transform = CGAffineTransform(scaleX: 1, y: -1)
    showsVerticalScrollIndicator = true
    keyboardDismissMode = .interactive

    coordinator.setupDataSource(self)
    setupObservers()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )

    let prefetchDS = ImagePrefetchDataSource(coordinator: coordinator)
    imagePrefetchDataSource = prefetchDS
    prefetchDataSource = prefetchDS
    prefetchDS.prefetchIfNeeded()
  }

  override func didMoveToWindow() {
    updateContentInsets()
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

  func updateContentInsets() {
    guard !UIMessageView.contextMenuOpen else {
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
    let messagesBottomPadding = 12.0
    var bottomInset: CGFloat = 0.0

    let hasReply = ChatState.shared.getState(peer: peerId).replyingMessageId != nil

    bottomInset += composeHeight + (ComposeView.textViewVerticalMargin * 2)
    bottomInset += messagesBottomPadding

    if hasReply {
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

  let threshold: CGFloat = -60
  var shouldScrollToBottom: Bool { contentOffset.y < threshold }
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

  private func findViewController() -> UIViewController? {
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
  }

  private var isKeyboardVisible: Bool = false
  private var keyboardHeight: CGFloat = 0

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
      UIView.animate(withDuration: 0.2) {
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

  private static func createLayout() -> UICollectionViewLayout {
    let layout = AnimatedCollectionViewLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.scrollDirection = .vertical
    layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
    return layout
  }
}

// MARK: - Coordinator

private extension MessagesCollectionView {
  class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
    private var currentCollectionView: UICollectionView?
    private let viewModel: MessagesProgressiveViewModel

    enum Section {
      case main
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, FullMessage.ID>!
    var messages: [FullMessage] { viewModel.messages }

    init(peerId: Peer) {
      viewModel = MessagesProgressiveViewModel(peer: peerId, reversed: true)

      super.init()

      viewModel.observe { [weak self] update in
        self?.applyUpdate(update)
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

        cell.configure(with: message, fromOtherSender: isFromDifferentSender)
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

    private func setInitialData() {
      var snapshot = NSDiffableDataSourceSnapshot<Section, FullMessage.ID>()

      // Only one section in this collection view, identified by Section.main
      snapshot.appendSections([.main])

      // Get identifiers of all message in our model and add to initial snapshot
      let itemIdentifiers = messages.map(\.id)

      snapshot.appendItems(itemIdentifiers, toSection: .main)

      dataSource.apply(snapshot, animatingDifferences: false)
    }

    func applyUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
      switch update {
        case let .added(newMessages, _):
          // get current snapshot and append new items
          var snapshot = dataSource.snapshot()
          let ids = newMessages.map(\.id)

          let shouldScroll = newMessages.contains {
            $0.message.fromId == Auth.shared.getCurrentUserId()
          }

          if let first = snapshot.itemIdentifiers.first {
            snapshot.insertItems(ids, beforeItem: first)
          } else {
            snapshot.appendItems(ids, toSection: .main)
          }
          UIView.animate(withDuration: 0.2) {
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
        case let .updated(newMessages, _):

          var snapshot = dataSource.snapshot()
          let ids = newMessages.map(\.id)

          snapshot.reconfigureItems(ids)

          dataSource.apply(snapshot, animatingDifferences: false)
        case .reload:
          setInitialData()
      }
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
        sizeCache.removeAll(keepingCapacity: true)
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

        dataSource.apply(snapshot, animatingDifferences: true)
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

    attributes.transform = CGAffineTransform(translationX: 0, y: -50)
    return attributes
  }
}

// Add new ImagePrefetchDataSource class
private class ImagePrefetchDataSource: NSObject, UICollectionViewDataSourcePrefetching {
  private weak var coordinator: MessagesCollectionView.Coordinator?
  private let pipeline = ImagePipeline {
    $0.imageCache = ImageCache(costLimit: 100 * 1_024 * 1_024) // 100MB memory cache
    $0.dataCache = try? DataCache(name: "com.inline.messages.images")
    $0.isProgressiveDecodingEnabled = true
    $0.isRateLimiterEnabled = true
  }

  init(coordinator: MessagesCollectionView.Coordinator) {
    self.coordinator = coordinator
    super.init()
  }

  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    guard let coordinator else { return }

    // Prioritize closer items
    let sortedIndexPaths = indexPaths.sorted { $0.item < $1.item }

    for indexPath in sortedIndexPaths {
      guard indexPath.item < coordinator.messages.count else { continue }
      let message = coordinator.messages[indexPath.item]

      if let file = message.file,
         let tempUrl = file.temporaryUrl,
         let url = URL(string: tempUrl)
      {
        // Check if image is already cached
        if PhotoView.imageCache.object(forKey: url.absoluteString as NSString) == nil {
          let request = ImageRequest(
            url: url,
            processors: [.resize(width: 300)], // Resize to reasonable size
            priority: .high
          )

          pipeline.loadImage(with: request) { _ in }
        }
      }
    }
  }

  func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
    // Cancel any in-progress prefetch requests if needed
  }

  func prefetchIfNeeded() {}
}

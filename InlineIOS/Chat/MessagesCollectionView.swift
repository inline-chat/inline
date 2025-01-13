import InlineKit
import UIKit

class MessagesCollectionView: UICollectionView {
  private let peerId: Peer
  private var coordinator: Coordinator

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
    // Basic setup
    backgroundColor = .clear
    delegate = coordinator
    autoresizingMask = [.flexibleHeight]

    // Register cell
    register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )

    // Bottom-up scrolling transform
    transform = CGAffineTransform(scaleX: 1, y: -1)

    // Performance optimizations
    isPrefetchingEnabled = true

    // Scroll indicator setup
    showsVerticalScrollIndicator = true

    keyboardDismissMode = .interactive

    coordinator.setupDataSource(self)
    setupKeyboardObservers()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
  }

  override func didMoveToWindow() {
    updateContentInsets()
    print("didMoveToWindow called")
  }

  private var composeHeight: CGFloat = ComposeView.minHeight
  public func updateComposeInset(composeHeight: CGFloat) {
    self.composeHeight = composeHeight
    UIView.animate(withDuration: 0.2) {
      self.updateContentInsets()
      self.scrollToItem(
        at: IndexPath(item: 0, section: 0),
        at: .top,
        animated: false
        //      animated: false
      )
    }
    print("updateComposeInset called")
  }

  func updateContentInsets() {
    guard let window = window else { return }
    let topContentPadding: CGFloat = 10
    let navBarHeight = (findViewController()?.navigationController?.navigationBar.frame.height ?? 0)
    let isLandscape = UIDevice.current.orientation.isLandscape
    let topSafeArea = isLandscape ? window.safeAreaInsets.left : window.safeAreaInsets.top
    let bottomSafeArea = isLandscape ? window.safeAreaInsets.right : window.safeAreaInsets.bottom
    let totalTopInset = topSafeArea + navBarHeight
    let messagesBottomPadding = 12.0
    var bottomInset: CGFloat = 0.0

    bottomInset += composeHeight
    bottomInset += messagesBottomPadding

    if isKeyboardVisible {
      bottomInset += keyboardHeight
    } else {
      bottomInset += bottomSafeArea
    }
    print("updateContentInsets called")

    contentInsetAdjustmentBehavior = .never
    automaticallyAdjustsScrollIndicatorInsets = false

    scrollIndicatorInsets = UIEdgeInsets(top: bottomInset, left: 0, bottom: totalTopInset, right: 0)
    contentInset = UIEdgeInsets(top: bottomInset, left: 0, bottom: totalTopInset + topContentPadding, right: 0)
    layoutIfNeeded()
  }

  @objc func orientationDidChange(_ notification: Notification) {
    guard !isKeyboardVisible else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.scrollToItem(
        at: IndexPath(item: 0, section: 0),
        at: .top,
        animated: false
      )

      self.updateContentInsets()
      UIView.animate(withDuration: 0.3) {
        // TODO: if at bottom already
        self.scrollToItem(
          at: IndexPath(item: 0, section: 0),
          at: .top,
          animated: true
        )
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

  private func setupKeyboardObservers() {
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
    print("keyboardWillShow called")
    let keyboardFrameHeight = keyboardFrame.height
    keyboardHeight = keyboardFrameHeight

    updateContentInsets()
    UIView.animate(withDuration: duration) {
      self.scrollToItem(
        at: IndexPath(item: 0, section: 0),
        at: .top,
//        animated: true
        animated: false
      )
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    isKeyboardVisible = false
    keyboardHeight = 0
    guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
      return
    }
    print("keyboardWillHide called")

    updateContentInsets()
    UIView.animate(withDuration: duration) {
      self.scrollToItem(
        at: IndexPath(item: 0, section: 0),
        at: .top,
        animated: true
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

// MARK: - Coordinator

private extension MessagesCollectionView {
  class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
    private var currentCollectionView: UICollectionView?
    private let viewModel: MessagesProgressiveViewModel

    enum Section {
      case main
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, FullMessage.ID>!
    private var messages: [FullMessage] { viewModel.messages }

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
      > { [weak self] cell, _, messageId in
        guard let self, let message = viewModel.messagesByID[messageId] else { return }

        cell.configure(with: message, topPadding: 2, bottomPadding: 0)
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

    private func setInitialData() {
      var snapshot = NSDiffableDataSourceSnapshot<Section, FullMessage.ID>()

      // Only one section in this collection view, identified by Section.main
      snapshot.appendSections([.main])

      // Get identifiers of all message in our model and add to initial snapshot
      let itemIdentifiers = messages.map { $0.id }

      snapshot.appendItems(itemIdentifiers, toSection: .main)

      dataSource.apply(snapshot, animatingDifferences: false)
    }

    func applyUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
      switch update {
      case .added(let newMessages, _):
        // get current snapshot and append new items
        var snapshot = dataSource.snapshot()
        let ids = newMessages.map { $0.id }

        if let first = snapshot.itemIdentifiers.first {
          snapshot.insertItems(ids, beforeItem: first)
        } else {
          snapshot.appendItems(ids, toSection: .main)
        }

        dataSource.apply(snapshot, animatingDifferences: true)
      case .deleted(let ids, _):
        var snapshot = dataSource.snapshot()

        snapshot.deleteItems(ids)

        dataSource.apply(snapshot, animatingDifferences: true)
      case .updated(let newMessages, let indexPaths):

        var snapshot = dataSource.snapshot()
        let ids = newMessages.map { $0.id }

        snapshot.reconfigureItems(ids)

        dataSource.apply(snapshot, animatingDifferences: false)

      case .reload:
        setInitialData()
      }
    }

    // MARK: - Helper Methods

    //    private func isTransitionFromOtherSender(at indexPath: IndexPath) -> Bool {
    //      guard indexPath.item < fullMessages.count else { return false }
    //
    //      let currentMessage = fullMessages[indexPath.item]
    //      let previousIndex = indexPath.item + 1 // Note: +1 because messages are reversed
    //
    //      guard previousIndex < fullMessages.count else { return true }
    //      let previousMessage = fullMessages[previousIndex]
    //
    //      let isFirstInGroup = currentMessage.message.out != previousMessage.message.out
    //
    //      return isFirstInGroup
    //    }
    //
    //    private func isTransitionToOtherSender(at indexPath: IndexPath) -> Bool {
    //      guard indexPath.item < fullMessages.count else { return false }
    //
    //      let currentMessage = fullMessages[indexPath.item]
    //      let nextIndex = indexPath.item + 1
    //
    //      guard nextIndex < fullMessages.count else { return false }
    //      let nextMessage = fullMessages[nextIndex]
    //
    //      return currentMessage.message.out != nextMessage.message.out
    //    }
    //
    //    // MARK: - UICollectionViewDelegateFlowLayout
    //
    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
      guard indexPath.item < messages.count else {
        return .zero
      }

      let availableWidth = collectionView.bounds.width - 16

      let cell = MessageCollectionViewCell(frame: .zero)
      let message = messages[indexPath.item]
      cell.configure(with: message, topPadding: 2, bottomPadding: 0)

      let size = cell.contentView.systemLayoutSizeFitting(
        CGSize(width: availableWidth, height: 0),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      )

      return size
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
      return 0
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      insetForSectionAt section: Int
    ) -> UIEdgeInsets {
      return .zero
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
      return 0
    }
  }
}

final class AnimatedCollectionViewLayout: UICollectionViewFlowLayout {
  override func prepare() {
    super.prepare()

    guard let collectionView = collectionView else { return }

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

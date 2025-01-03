import InlineKit
import SwiftUI
import UIKit

struct MessagesCollectionView: UIViewRepresentable {
  var peerId: Peer

  init(peerId: Peer) {
    self.peerId = peerId
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(peerId: peerId)
  }

  func makeUIView(context: Context) -> UICollectionView {
    let layout = createLayout()

    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    // Basic setup
    collectionView.backgroundColor = .clear
    collectionView.delegate = context.coordinator
    collectionView.autoresizingMask = [.flexibleHeight]

    // Register cell
    collectionView.register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )

    // Bottom-up scrolling transform
    collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)

    // Performance optimizations
    collectionView.isPrefetchingEnabled = true
    collectionView.decelerationRate = .normal
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.isDirectionalLockEnabled = true

    // Scroll indicator setup
    collectionView.showsVerticalScrollIndicator = true
    collectionView.indicatorStyle = .default
    collectionView.scrollIndicatorInsets = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
    collectionView.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)

    context.coordinator.setupDataSource(collectionView)

    // Observe orientation changes
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )

    return collectionView
  }

  private func createLayout() -> UICollectionViewLayout {
    //    let layout = UICollectionViewFlowLayout()
    let layout = AnimatedCollectionViewLayout()

    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.scrollDirection = .vertical
    layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
    return layout
  }

  func updateUIView(_ collectionView: UICollectionView, context: Context) {
    //    context.coordinator.updateMessages(fullMessages)
  }
}

// MARK: - Coordinator

extension MessagesCollectionView {
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

    @objc func orientationDidChange(_ notification: Notification) {
      guard let collectionView = currentCollectionView else { return }

      UIView.performWithoutAnimation {
        collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        //          self.adjustContentInset(for: collectionView)
        collectionView.collectionViewLayout.invalidateLayout()

        //          if !self.fullMessages.isEmpty {
        //            collectionView.scrollToItem(
        //              at: IndexPath(item: 0, section: 0),
        //              at: .bottom,
        //              animated: false
        //            )
        //          }
      }
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

  //
  //  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
  //    return true
  //  }

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

// final class AnimatedCollectionViewLayout: UICollectionViewFlowLayout {
//  override func prepare() {
//    super.prepare()
//    print("PREPAREING")
//    guard let collectionView = collectionView else { return }
//
//    // Calculate the available width
//    let availableWidth = collectionView.bounds.width - sectionInset.left - sectionInset.right
//    print("availableWidth \(availableWidth)")
//
//    // Set the width that cells should use
//    itemSize = CGSize(width: availableWidth, height: 44)
//    print("itemSize \(itemSize)")
//  }
//
//  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
//    -> UICollectionViewLayoutAttributes?
//  {
//    guard
//      let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)?.copy()
//      as? UICollectionViewLayoutAttributes
//    else {
//      return nil
//    }
//
//    attributes.transform = CGAffineTransform(translationX: 0, y: -50)
//
//    print("attributes \(attributes)")
//    return attributes
//  }
// }

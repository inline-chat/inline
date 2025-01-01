import InlineKit
import SwiftUI
import UIKit

struct MessagesCollectionView: UIViewRepresentable {
  var fullMessages: [FullMessage]

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
    context.coordinator.updateMessages(fullMessages)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(fullMessages: fullMessages)
  }
}

// MARK: - Coordinator

extension MessagesCollectionView {
  class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
    private var dataSource: UICollectionViewDiffableDataSource<Section, FullMessage.ID>!
    private var messagesById: [FullMessage.ID: FullMessage] = [:]
    // Ordered list of messages because dictionary can't be ordered
    private var fullMessages: [FullMessage] = []
    private var currentCollectionView: UICollectionView?

    enum Section {
      case main
    }

    init(fullMessages: [FullMessage]) {
      self.fullMessages = fullMessages
      super.init()
      updateMessagesCache(fullMessages)
    }

    private func updateMessagesCache(_ messages: [FullMessage]) {
      fullMessages = messages
      //      messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.message.globalId ?? $0.message.id, $0) })

      messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.message.id, $0) })
    }

    func setupDataSource(_ collectionView: UICollectionView) {
      currentCollectionView = collectionView

      dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
        [weak self] collectionView, indexPath, id in
        guard let self,
              let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MessageCollectionViewCell.reuseIdentifier,
                for: indexPath
              ) as? MessageCollectionViewCell,
              let message = self.messagesById[id]
        else {
          return nil
        }

        cell.configure(with: message, topPadding: 2, bottomPadding: 0)
        return cell
      }

      // Apply initial data
      var snapshot = NSDiffableDataSourceSnapshot<Section, FullMessage.ID>()
      snapshot.appendSections([.main])
      snapshot.appendItems(Array(messagesById.keys))
      dataSource.apply(snapshot, animatingDifferences: false)
    }

    var isAnimatingUpdate: Bool = false
    var pendingMessages: [FullMessage]? = nil

    func updateMessages(_ messages: [FullMessage]) {
      guard !isAnimatingUpdate else {
        pendingMessages = messages
        return
      }

      // Update cache before creating snapshot
      updateMessagesCache(messages)

      var snapshot = NSDiffableDataSourceSnapshot<Section, FullMessage.ID>()
      snapshot.appendSections([.main])

      // Use the message IDs from the updated messagesById dictionary
      snapshot.appendItems(fullMessages.map { $0.message.id })

      let hasNewMessages = fullMessages.first?.message.globalId != messages.first?.message.globalId

      print(
        "hasNewMessages \(hasNewMessages) - \(fullMessages.first?.message.globalId) - \(messages.first?.message.globalId)"
      )
      let animated = hasNewMessages
      print("animated \(animated)")

      if animated {
        isAnimatingUpdate = true
        print("Here :)")
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
          guard let self else { return }
          self.isAnimatingUpdate = false

          if let pendingMessages = self.pendingMessages {
            self.updateMessages(pendingMessages)
            self.pendingMessages = nil
          }
        }
      } else {
        print("Here :(")
        dataSource.apply(snapshot, animatingDifferences: false)
      }
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

    // MARK: - Helper Methods

    private func isTransitionFromOtherSender(at indexPath: IndexPath) -> Bool {
      guard indexPath.item < fullMessages.count else { return false }

      let currentMessage = fullMessages[indexPath.item]
      let previousIndex = indexPath.item + 1 // Note: +1 because messages are reversed

      guard previousIndex < fullMessages.count else { return true }
      let previousMessage = fullMessages[previousIndex]

      let isFirstInGroup = currentMessage.message.out != previousMessage.message.out

      return isFirstInGroup
    }

    private func isTransitionToOtherSender(at indexPath: IndexPath) -> Bool {
      guard indexPath.item < fullMessages.count else { return false }

      let currentMessage = fullMessages[indexPath.item]
      let nextIndex = indexPath.item + 1

      guard nextIndex < fullMessages.count else { return false }
      let nextMessage = fullMessages[nextIndex]

      return currentMessage.message.out != nextMessage.message.out
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
      guard indexPath.item < fullMessages.count else {
        return .zero
      }

      let availableWidth = collectionView.bounds.width - 16

      let cell = MessageCollectionViewCell(frame: .zero)
      let message = fullMessages[indexPath.item]
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

    attributes.transform = CGAffineTransform(translationX: 0, y: -30)
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

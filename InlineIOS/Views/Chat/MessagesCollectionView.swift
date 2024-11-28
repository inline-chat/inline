import InlineKit
import SwiftUI
import UIKit

struct MessagesCollectionView: UIViewRepresentable {
  var fullMessages: [FullMessage]

  func makeUIView(context: Context) -> UICollectionView {
    let layout = createLayout()
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    collectionView.backgroundColor = .clear
    collectionView.delegate = context.coordinator
    collectionView.register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )

    // Base transform for bottom-up scrolling
    collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
    collectionView.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
    collectionView.keyboardDismissMode = .none

    // Performance optimizations
    collectionView.isPrefetchingEnabled = true
    collectionView.decelerationRate = .normal

    context.coordinator.setupDataSource(collectionView)

    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )

    return collectionView
  }

  private func createLayout() -> UICollectionViewLayout {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.scrollDirection = .vertical
    layout.estimatedItemSize = .zero
    return layout
  }

  func updateUIView(_ collectionView: UICollectionView, context: Context) {
    context.coordinator.updateMessages(fullMessages, in: collectionView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(fullMessages: fullMessages)
  }

  class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
    private var dataSource: UICollectionViewDiffableDataSource<Int, FullMessage>!
    private var fullMessages: [FullMessage]
    private weak var currentCollectionView: UICollectionView?
    private var previousMessageCount: Int = 0
    private var isPerformingBatchUpdate = false

    // Scroll position tracking
    private struct ScrollAnchor {
      let messageId: Int64
      let offsetFromTop: CGFloat
    }

    private var scrollAnchor: ScrollAnchor?

    init(fullMessages: [FullMessage]) {
      self.fullMessages = fullMessages
      self.previousMessageCount = fullMessages.count
      super.init()
    }

    func setupDataSource(_ collectionView: UICollectionView) {
      currentCollectionView = collectionView

      dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
        [weak self] collectionView, indexPath, fullMessage in
        guard let self else { return nil }

        guard
          let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MessageCollectionViewCell.reuseIdentifier,
            for: indexPath
          ) as? MessageCollectionViewCell
        else {
          return nil
        }

        let topPadding = isTransitionFromOtherSender(at: indexPath) ? 24.0 : 2.0

        cell.configure(with: fullMessage, topPadding: topPadding, bottomPadding: 0)

        return cell
      }

      applyInitialData()
    }

    private func applyInitialData() {
      updateSnapshot(with: fullMessages, animated: false)
    }

    private func updateSnapshot(with messages: [FullMessage], animated: Bool) {
      // Skip if already updating
      guard !isPerformingBatchUpdate else { return }
      isPerformingBatchUpdate = true

      // Pre-calculate sizes in background
      //      Task.detached { @MainActor [weak self] in
      //      guard let self = self else { return }

      // Create snapshot without animation first
      var snapshot = NSDiffableDataSourceSnapshot<Int, FullMessage>()
      snapshot.appendSections([0])
      snapshot.appendItems(messages)

      // Apply immediately without animation
      dataSource.apply(snapshot, animatingDifferences: animated)
      isPerformingBatchUpdate = false

      // Ensure transforms are correct after update
      ensureCorrectTransforms(in: currentCollectionView)
      //      }
    }

    private func ensureCorrectTransforms(in collectionView: UICollectionView?) {
      guard let collectionView = collectionView else { return }

      UIView.performWithoutAnimation {
        collectionView.visibleCells.forEach { cell in
          cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        }
      }
    }

    private func captureScrollPosition(_ collectionView: UICollectionView) {
      // Only capture if we're not at the top (y: 0 in flipped scroll view)
      guard collectionView.contentOffset.y > 0,
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems.min(),
        visibleIndexPaths.item < fullMessages.count
      else {
        scrollAnchor = nil
        return
      }

      let anchorMessage = fullMessages[visibleIndexPaths.item]
      let cell = collectionView.cellForItem(at: visibleIndexPaths)
      let cellFrame = cell?.frame ?? .zero
      let offsetFromTop = collectionView.contentOffset.y - cellFrame.minY

      scrollAnchor = ScrollAnchor(
        messageId: anchorMessage.message.id,
        offsetFromTop: offsetFromTop
      )
    }

    private func restoreScrollPosition(_ collectionView: UICollectionView) {
      guard let anchor = scrollAnchor,
        let anchorIndex = fullMessages.firstIndex(where: { $0.message.id == anchor.messageId })
      else {
        return
      }

      let indexPath = IndexPath(item: anchorIndex, section: 0)

      // Get the frame of the anchor cell
      if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
        let targetOffset = attributes.frame.minY + anchor.offsetFromTop
        collectionView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
      }
    }

    func updateMessages(_ messages: [FullMessage], in collectionView: UICollectionView) {
      // Capture scroll position before update if needed
      captureScrollPosition(collectionView)

      let oldCount = fullMessages.count
      let oldMessages = fullMessages
      fullMessages = messages

      // Only scroll to bottom if the new message is from us
      if messages.count > oldCount {
        let newMessages = messages.filter { message in
          !oldMessages.contains { $0.message.id == message.message.id }
        }

        // Check if any of the new messages are from us
        let hasOurNewMessage = newMessages.contains { $0.message.out == true }

        if hasOurNewMessage {
          // First update the data without animation
          updateSnapshot(with: messages, animated: true)

          // Then perform the animation
          UIView.performWithoutAnimation {
            // Scroll to bottom without animation
            collectionView.scrollToItem(
              at: IndexPath(item: 0, section: 0),
              at: .bottom,
              animated: true
            )

            // Get the latest message cell and prepare it for animation
            if let latestCell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) {
              latestCell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
              // latestCell.transform = CGAffineTransform(scaleX: 0.95, y: 0.95).translatedBy(
              //   x: 0, y: 10
              // )

              // Animate to final state
              UIView.animate(
                withDuration: 0.2,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.2,
                options: [.curveEaseIn]
              ) {
                latestCell.transform = .identity
              }
            }
          }
        } else {
          // Restore previous scroll position for messages from others
          updateSnapshot(with: messages, animated: true)
          DispatchQueue.main.async { [weak self] in
            self?.restoreScrollPosition(collectionView)
          }
        }
      } else {
        updateSnapshot(with: messages, animated: false)
      }

      previousMessageCount = messages.count
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      ensureCorrectTransforms(in: currentCollectionView)
    }

    @objc func orientationDidChange(_ notification: Notification) {
      guard let collectionView = currentCollectionView else { return }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self else { return }

        UIView.performWithoutAnimation {
          collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
          self.ensureCorrectTransforms(in: collectionView)
          collectionView.collectionViewLayout.invalidateLayout()

          if !self.fullMessages.isEmpty {
            collectionView.scrollToItem(
              at: IndexPath(item: 0, section: 0),
              at: .bottom,
              animated: false
            )
          }
        }
      }
    }

    // MARK: - Helper Methods

    private func isTransitionFromOtherSender(at indexPath: IndexPath) -> Bool {
      guard indexPath.item < fullMessages.count else { return false }

      let currentMessage = fullMessages[indexPath.item]
      let previousIndex = indexPath.item + 1  // Note: +1 because messages are reversed

      // If this is the first message in a group from the same sender,
      // check if the previous message was from a different sender
      guard previousIndex < fullMessages.count else { return true }
      let previousMessage = fullMessages[previousIndex]

      // Check if this is the first message in a sequence from the same sender
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
      guard indexPath.item < fullMessages.count else { return .zero }

      let fullMessage = fullMessages[indexPath.item]
      let width = collectionView.bounds.width - 28

      let topPadding = isTransitionFromOtherSender(at: indexPath) ? 24.0 : 2.0

      let messageView = UIMessageView(fullMessage: fullMessage)
      messageView.frame = CGRect(
        x: 0, y: 0, width: width, height: UIView.layoutFittingCompressedSize.height
      )
      let size = messageView.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      )

      return CGSize(width: width, height: size.height + topPadding)
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

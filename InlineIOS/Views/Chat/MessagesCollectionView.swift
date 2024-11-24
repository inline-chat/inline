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
    collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "MessageCell")

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

        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: "MessageCell",
          for: indexPath
        )

        configureCell(cell, at: indexPath, with: fullMessage)

        // Apply transform immediately after configuration
        cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        return cell
      }

      applyInitialData()
    }

    private func applyInitialData() {
      updateSnapshot(with: fullMessages, animated: false)
    }

    private func configureCell(
      _ cell: UICollectionViewCell,
      at indexPath: IndexPath,
      with message: FullMessage
    ) {
      let topPadding = isTransitionFromOtherSender(at: indexPath) ? 24.0 : 1.0
      let bottomPadding = isTransitionToOtherSender(at: indexPath) ? 24.0 : 1.0

      cell.contentConfiguration = UIHostingConfiguration {
        MessageView(fullMessage: message)
          .padding(.bottom, topPadding)
          .padding(.top, bottomPadding)
      }
    }

    private func updateSnapshot(with messages: [FullMessage], animated: Bool) {
      // Skip if already updating
      guard !isPerformingBatchUpdate else { return }
      isPerformingBatchUpdate = true

      // Pre-calculate sizes in background
      Task.detached { @MainActor [weak self] in
        guard let self = self else { return }

        // Create snapshot without animation first
        var snapshot = NSDiffableDataSourceSnapshot<Int, FullMessage>()
        snapshot.appendSections([0])
        snapshot.appendItems(messages)

        // Apply immediately without animation
        await self.dataSource.apply(snapshot, animatingDifferences: false)
        self.isPerformingBatchUpdate = false

        // Ensure transforms are correct after update
        self.ensureCorrectTransforms(in: self.currentCollectionView)
      }
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

      updateSnapshot(with: messages, animated: false)

      // Only scroll to bottom if the new message is from us
      if messages.count > oldCount {
        let newMessages = messages.filter { message in
          !oldMessages.contains { $0.message.id == message.message.id }
        }

        // Check if any of the new messages are from us
        let hasOurNewMessage = newMessages.contains { $0.message.out == true }

        if hasOurNewMessage {
          DispatchQueue.main.async { [weak self] in
            collectionView.scrollToItem(
              at: IndexPath(item: 0, section: 0),
              at: .bottom,
              animated: true
            )
          }
        } else {
          // Restore previous scroll position for messages from others
          DispatchQueue.main.async { [weak self] in
            self?.restoreScrollPosition(collectionView)
          }
        }
      }

      previousMessageCount = messages.count
    }

    private func animateNewMessages(
      _ newMessages: [FullMessage], in collectionView: UICollectionView
    ) {
      guard !newMessages.isEmpty else { return }

      let indexPaths = newMessages.enumerated().map { IndexPath(item: $0.offset, section: 0) }
      let cells = indexPaths.compactMap { collectionView.cellForItem(at: $0) }

      cells.enumerated().forEach { index, cell in
        // Ensure content view has correct transform
        cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        // Initial animation state
        let scale = CGAffineTransform(scaleX: 0.98, y: 0.98)
        let translation = CGAffineTransform(translationX: 0, y: -24)
        cell.transform = scale.concatenating(translation)

        UIView.animate(
          withDuration: 0.35,
          delay: Double(index) * 0.04,
          usingSpringWithDamping: 0.82,
          initialSpringVelocity: 0.4,
          options: [.curveEaseOut, .allowUserInteraction]
        ) {
          cell.transform = .identity
        }
      }
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
      let previousIndex = indexPath.item - 1

      guard previousIndex >= 0, previousIndex < fullMessages.count else { return false }
      let previousMessage = fullMessages[previousIndex]

      return currentMessage.message.out != previousMessage.message.out
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
      let width = collectionView.bounds.width - 16

      let topPadding = isTransitionFromOtherSender(at: indexPath) ? 24.0 : 1.0
      let bottomPadding = isTransitionToOtherSender(at: indexPath) ? 24.0 : 1.0

      let messageView = MessageView(fullMessage: fullMessage)
      let messageSize = UIHostingController(rootView: messageView).sizeThatFits(
        in: CGSize(width: width, height: .infinity))

      return CGSize(width: width, height: messageSize.height + topPadding + bottomPadding)
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

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

    func updateMessages(_ messages: [FullMessage], in collectionView: UICollectionView) {
      let oldCount = self.fullMessages.count
      self.fullMessages = messages

      // Apply updates immediately without waiting
      updateSnapshot(with: messages, animated: false)

      // Handle new messages if any
      if messages.count > oldCount {
        let newMessages = messages.prefix(messages.count - oldCount)

        // Optimize animation by doing it in next run loop
        DispatchQueue.main.async { [weak self] in
          self?.animateNewMessages(Array(newMessages), in: collectionView)
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

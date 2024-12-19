import InlineKit
import SwiftUI
import UIKit

struct MessagesCollectionView: UIViewRepresentable {
  var fullMessages: [FullMessage]

  func makeUIView(context: Context) -> UICollectionView {
    let layout = createLayout()

    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    collectionView.collectionViewLayout = layout
//    collectionView.contentInsetAdjustmentBehavior = .always // added for width
    collectionView.backgroundColor = .clear
    collectionView.delegate = context.coordinator
    collectionView.autoresizingMask = [.flexibleHeight]
//    collectionView.automaticallyAdjustsScrollIndicatorInsets = false
    collectionView.register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )

    // Base transform for bottom-up scrolling
    collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)

    // Performance optimizations
    collectionView.isPrefetchingEnabled = true
    collectionView.decelerationRate = .normal
    collectionView.contentInsetAdjustmentBehavior = .never

    // Improve scrolling performance
    collectionView.isDirectionalLockEnabled = true
    collectionView.showsVerticalScrollIndicator = true
    collectionView.indicatorStyle = .default

    // Memory optimization
    collectionView.remembersLastFocusedIndexPath = false

    // Fix for scroll indicator
    collectionView.scrollIndicatorInsets = .zero
    collectionView.verticalScrollIndicatorInsets = .zero
//    context.coordinator.adjustContentInset(for: collectionView)

    // Get navigation bar height
//    let navBarHeight = getNavigationBarHeight()
//
//    // Set scroll indicator insets instead of content inset
//    collectionView.scrollIndicatorInsets = UIEdgeInsets(
//      top: 0,
//      left: 0,
//      bottom: navBarHeight,
//      right: 0
//    )
//
//    // Content inset can be different if needed
//    collectionView.contentInset = UIEdgeInsets(
//      top: 0, // Adjust this value based on your needs
//      left: 0,
//      bottom: navBarHeight,
//      right: 0
//    )
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
    let layout = AnimatedCollectionViewLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.scrollDirection = .vertical
    layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
    return layout
  }

  func updateUIView(_ collectionView: UICollectionView, context: Context) {
    context.coordinator.updateMessages(fullMessages, in: collectionView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(fullMessages: fullMessages)
  }

  class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
    private var log = Log.scoped("MessageCollectionView", enableTracing: true)
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

    func getNavigationBarHeight() -> CGFloat {
      let fallback: CGFloat = 44.0
      let minimumNavHeight: CGFloat = 32.0

      guard let windowScene = UIApplication.shared
        .connectedScenes
        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        let window = windowScene.windows.first(where: { $0.isKeyWindow })
      else {
        return fallback
      }

      let orientation = windowScene.interfaceOrientation
      let safeAreaTop = window.safeAreaInsets.top

      switch orientation {
      case .portrait, .portraitUpsideDown:
        return safeAreaTop + 10.0
      case .landscapeLeft, .landscapeRight:
        return max(safeAreaTop + 32.0, minimumNavHeight)
      case .unknown:
        return fallback
      @unknown default:
        return fallback
      }
    }

//    func adjustContentInset(for collectionView: UICollectionView) {
//      let navH = getNavigationBarHeight()
//
//      collectionView.scrollIndicatorInsets = UIEdgeInsets(
//        top: 0,
//        left: 0,
//        bottom: navH,
//        right: 0
//      )
//
//      // Content inset can be different if needed
//      collectionView.contentInset = UIEdgeInsets(
//        top: 0, // Adjust this value based on your needs
//        left: 0,
//        bottom: navH,
//        right: 0
//      )
//    }

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

        let topPadding = 2.0

        cell.configure(with: fullMessage, topPadding: topPadding, bottomPadding: 0)

        return cell
      }

      applyInitialData()
    }

    private func applyInitialData() {
      updateSnapshot(with: fullMessages)
    }

    func adjustContentInset(for collectionView: UICollectionView, navBarHeight: CGFloat) {
      // Get navigation bar height

      // Set scroll indicator insets instead of content inset
      collectionView.scrollIndicatorInsets = UIEdgeInsets(
        top: 0,
        left: 0,
        bottom: navBarHeight,
        right: 0
      )

      // Content inset can be different if needed
      collectionView.contentInset = UIEdgeInsets(
        top: 0, // Adjust this value based on your needs
        left: 0,
        bottom: navBarHeight,
        right: 0
      )
    }

    private func updateSnapshot(with messages: [FullMessage]) {
      guard !isPerformingBatchUpdate else { return }
      var animated = false
      //      isPerformingBatchUpdate = true

      log.trace("updateSnapshot \(messages.count) animated=\(animated)")

      // Prevent animation when id or message changes
      if fullMessages.count != messages.count {
        animated = true
      }

      var snapshot = NSDiffableDataSourceSnapshot<Int, FullMessage>()

      snapshot.appendSections([0])
      snapshot.appendItems(messages)

      // Use UIView.animate for custom animations
      if animated {
        dataSource.apply(snapshot, animatingDifferences: true)
      } else {
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
          guard let self else { return }
          isPerformingBatchUpdate = false
        }
      }
      fullMessages = messages
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
      let oldCount = fullMessages.count
      let oldMessages = fullMessages

      if messages.count > oldCount {
        let newMessages = messages.filter { message in
          !oldMessages.contains { $0.message.id == message.message.id }
        }

        let hasOurNewMessage = newMessages.contains { $0.message.out == true }

        if hasOurNewMessage {
          updateSnapshot(with: messages)
        } else {
          updateSnapshot(with: messages)
          DispatchQueue.main.async { [weak self] in
            self?.restoreScrollPosition(collectionView)
          }
        }
      } else {
        fullMessages = messages
        updateSnapshot(with: messages)
      }

      previousMessageCount = messages.count
    }

    @objc func orientationDidChange(_ notification: Notification) {
      guard let collectionView = currentCollectionView else { return }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in

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
    }

    // MARK: - Helper Methods

    private func isTransitionFromOtherSender(at indexPath: IndexPath) -> Bool {
      guard indexPath.item < fullMessages.count else { return false }

      let currentMessage = fullMessages[indexPath.item]
      let previousIndex = indexPath.item + 1 // Note: +1 because messages are reversed

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

    //    func collectionView(
    //      _ collectionView: UICollectionView,
    //      layout collectionViewLayout: UICollectionViewLayout,
    //      sizeForItemAt indexPath: IndexPath
    //    ) -> CGSize {
    //      guard indexPath.item < fullMessages.count else { return .zero }
    //
    //      let fullMessage = fullMessages[indexPath.item]
    //      let width = collectionView.bounds.width
    //      let isTransition = isTransitionFromOtherSender(at: indexPath)
    //
    //      return MessageSizeCalculator.shared.size(
    //        for: fullMessage,
    //        maxWidth: width,
    //        isTransition: isTransition
    //      )
    //    }

//    func collectionView(
//      _ collectionView: UICollectionView,
//      layout collectionViewLayout: UICollectionViewLayout,
//      sizeForItemAt indexPath: IndexPath
//    ) -> CGSize {
//      let availableWidth = collectionView.bounds.width - collectionView.contentInset.left - collectionView.contentInset.right
//      return CGSize(width: availableWidth, height: UICollectionViewFlowLayout.automaticSize.height)
//    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
      let availableWidth = collectionView.bounds.width - 25

      // Return full width with estimated height
      // Actual height will be adjusted by the cell's preferredLayoutAttributesFitting
      return CGSize(width: availableWidth, height: 1)
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

    // Set the width that cells should use
    itemSize = CGSize(width: availableWidth, height: 1) // Height will be determined automatically
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    guard let collectionView = collectionView else { return false }
    return collectionView.bounds.width != newBounds.width
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

    // Initial state: moved down and slightly scaled
    attributes.transform = CGAffineTransform(translationX: 0, y: -50)
    //    attributes.alpha = 0

    return attributes
  }
}

import InlineKit
import SwiftUI
import UIKit

// MARK: - MessageCell
final class MessageCell: UICollectionViewCell {
  private var hostingController: UIHostingController<AnyView>?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with message: FullMessage, topPadding: CGFloat, bottomPadding: CGFloat) {
    let messageView = MessageView(fullMessage: message)
      .padding(.bottom, topPadding)
      .padding(.top, bottomPadding)
      .padding(.horizontal, 16)

    if hostingController == nil {
      let hosting = UIHostingController(rootView: AnyView(messageView))
      hostingController = hosting

      hosting.view.backgroundColor = .clear
      contentView.addSubview(hosting.view)
      hosting.view.frame = contentView.bounds
      hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    } else {
      hostingController?.rootView = AnyView(messageView)
    }

    contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    contentView.transform = .identity
  }
}

// MARK: - MessagesCollectionView
struct MessagesCollectionView: UIViewRepresentable {
  var fullMessages: [FullMessage]

  func makeUIView(context: Context) -> UICollectionView {
    let layout = createLayout()
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    collectionView.backgroundColor = .clear
    collectionView.delegate = context.coordinator
    collectionView.prefetchDataSource = context.coordinator
    collectionView.register(MessageCell.self, forCellWithReuseIdentifier: "MessageCell")

    collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
    collectionView.contentInset = .zero
    collectionView.keyboardDismissMode = .none

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
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(100)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(100)
    )
    let group = NSCollectionLayoutGroup.vertical(
      layoutSize: groupSize,
      subitems: [item]
    )

    let section = NSCollectionLayoutSection(group: group)
    section.contentInsets = NSDirectionalEdgeInsets(
      top: 16,
      leading: 0,
      bottom: 16,
      trailing: 0
    )

    let config = UICollectionViewCompositionalLayoutConfiguration()
    config.scrollDirection = .vertical

    return UICollectionViewCompositionalLayout(section: section, configuration: config)
  }

  func updateUIView(_ collectionView: UICollectionView, context: Context) {
    context.coordinator.updateMessages(fullMessages, in: collectionView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(fullMessages: fullMessages)
  }

  // MARK: - Coordinator
  class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    private var dataSource: UICollectionViewDiffableDataSource<Int, FullMessage>!
    private var fullMessages: [FullMessage]
    private weak var currentCollectionView: UICollectionView?
    private var previousMessageCount: Int = 0
    private var isPerformingBatchUpdate = false
    private var cellSizeCache: NSCache<NSNumber, NSValue> = {
      let cache = NSCache<NSNumber, NSValue>()
      cache.countLimit = 1000
      return cache
    }()

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

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath])
    {
      for indexPath in indexPaths {
        guard indexPath.item < fullMessages.count else { continue }
        let message = fullMessages[indexPath.item]
        calculateAndCacheSize(for: message, width: collectionView.bounds.width)
      }
    }

    private func calculateAndCacheSize(for message: FullMessage, width: CGFloat) -> CGSize {
      let cacheKey = NSNumber(value: message.message.id)

      if let cachedSize = cellSizeCache.object(forKey: cacheKey) {
        return cachedSize.cgSizeValue
      }

      let messageView = MessageView(fullMessage: message)
        .padding(.horizontal, 16)

      let size = UIHostingController(rootView: messageView).sizeThatFits(
        in: CGSize(width: width, height: .infinity)
      )

      cellSizeCache.setObject(NSValue(cgSize: size), forKey: cacheKey)
      return size
    }

    func setupDataSource(_ collectionView: UICollectionView) {
      currentCollectionView = collectionView

      dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
        [weak self] collectionView, indexPath, fullMessage in
        guard let self else { return nil }

        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: "MessageCell",
            for: indexPath
          ) as! MessageCell

        let topPadding = isTransitionFromOtherSender(at: indexPath) ? 24.0 : 1.0
        let bottomPadding = isTransitionToOtherSender(at: indexPath) ? 24.0 : 1.0

        cell.configure(
          with: fullMessage,
          topPadding: topPadding,
          bottomPadding: bottomPadding
        )

        return cell
      }

      applyInitialData()
    }

    private func applyInitialData() {
      var snapshot = NSDiffableDataSourceSnapshot<Int, FullMessage>()
      snapshot.appendSections([0])
      snapshot.appendItems(fullMessages)
      dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func captureScrollPosition(_ collectionView: UICollectionView) {
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

      if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
        let targetOffset = attributes.frame.minY + anchor.offsetFromTop
        collectionView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
      }
    }

    func updateMessages(_ messages: [FullMessage], in collectionView: UICollectionView) {
      captureScrollPosition(collectionView)

      let oldCount = fullMessages.count
      let oldMessages = fullMessages
      fullMessages = messages

      var snapshot = NSDiffableDataSourceSnapshot<Int, FullMessage>()
      snapshot.appendSections([0])
      snapshot.appendItems(messages)

      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        guard let self = self else { return }

        if messages.count > oldCount {
          let newMessages = messages.filter { message in
            !oldMessages.contains { $0.message.id == message.message.id }
          }

          let hasOurNewMessage = newMessages.contains { $0.message.out == true }

          if hasOurNewMessage {
            collectionView.scrollToItem(
              at: IndexPath(item: 0, section: 0),
              at: .bottom,
              animated: true
            )
            self.animateNewMessages(newMessages, in: collectionView)
          } else {
            self.restoreScrollPosition(collectionView)
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
        let scale = CGAffineTransform(scaleX: 0.98, y: 0.98)
        let translation = CGAffineTransform(translationX: 0, y: -24)
        cell.transform = scale.concatenating(translation)

        UIView.animate(
          withDuration: 0.22,
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
      guard let collectionView = currentCollectionView else { return }

      collectionView.visibleCells.forEach { cell in
        cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
      }
    }

    @objc func orientationDidChange(_ notification: Notification) {
      guard let collectionView = currentCollectionView else { return }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self else { return }

        UIView.performWithoutAnimation {
          collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
          collectionView.visibleCells.forEach { cell in
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
          }
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
  }
}

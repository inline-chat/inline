import InlineKit
import UIKit

final class MessagesCollectionView: UIView {
  private let collectionView: UICollectionView
  private let coordinator: Coordinator
    
  init(messages: [FullMessage]) {
    // Initialize coordinator with messages
    self.coordinator = Coordinator(fullMessages: messages)
        
    // Create a temporary layout for initialization
    let tempLayout = UICollectionViewFlowLayout()
    self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: tempLayout)
        
    super.init(frame: .zero)
        
    // Now we can setup the real layout
    let layout = createLayout()
    collectionView.setCollectionViewLayout(layout, animated: false)
        
    setupCollectionView()
    setupConstraints()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  private func createLayout() -> UICollectionViewLayout {
    let layout = AnimatedCollectionViewLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.scrollDirection = .vertical
    layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
    return layout
  }
    
  private func setupCollectionView() {
    collectionView.backgroundColor = .clear
    collectionView.delegate = coordinator
    collectionView.autoresizingMask = [.flexibleHeight]
    collectionView.register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )
        
    collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
    coordinator.setupDataSource(collectionView)
  }
    
  private func setupConstraints() {
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(collectionView)
        
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }
    
  func updateMessages(_ messages: [FullMessage]) {
    coordinator.updateMessages(messages, in: collectionView)
  }
}

// MARK: - Coordinator
    
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
            
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
  }
        
  func getNavigationBarHeight() -> CGFloat {
    let fallback: CGFloat = 44.0
    let minimumNavHeight: CGFloat = 32.0
            
    guard
      let windowScene = UIApplication.shared
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
        
  private func updateSnapshot(with messages: [FullMessage]) {
    guard !isPerformingBatchUpdate else { return }
    var animated = false
            
    log.trace("updateSnapshot \(messages.count) animated=\(animated)")
            
    if fullMessages.count != messages.count {
      animated = true
    }
            
    var snapshot = NSDiffableDataSourceSnapshot<Int, FullMessage>()
    snapshot.appendSections([0])
    snapshot.appendItems(messages)
            
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
        captureScrollPosition(collectionView)
        updateSnapshot(with: messages)
        restoreScrollPosition(collectionView)
      }
    } else {
      fullMessages = messages
      updateSnapshot(with: messages)
    }
            
    previousMessageCount = messages.count
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
        
  @objc func orientationDidChange(_ notification: Notification) {
    guard let collectionView = currentCollectionView else { return }
    print("orientationDidChange \(notification)")
            
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else { return }
                
      UIView.performWithoutAnimation {
        collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        collectionView.collectionViewLayout.invalidateLayout()
      }
    }
  }
        
  // MARK: - UICollectionViewDelegateFlowLayout
        
  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let availableWidth = collectionView.bounds.width - 25
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

final class AnimatedCollectionViewLayout: UICollectionViewFlowLayout {
  override func prepare() {
    super.prepare()

    guard let collectionView = collectionView else { return }

    // Calculate the available width
    let availableWidth = collectionView.bounds.width - sectionInset.left - sectionInset.right

    // Set the width that cells should use
    itemSize = CGSize(width: availableWidth, height: 1) // Height will be determined automatically
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

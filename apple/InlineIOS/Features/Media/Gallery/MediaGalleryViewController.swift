import AVFoundation
import Combine
import InlineKit
import Logger
import Nuke
import Photos
import UIKit

/// Full-screen photo and video gallery.
///
/// - Opens with a hero morph from the tapped thumbnail and closes back into the bubble of
///   whichever item is on screen.
/// - Pages follow the finger with a gap between items; older items load as the user nears them.
/// - Drag vertically to dismiss, pinch or double-tap to zoom, tap to show or hide the chrome.
@MainActor
final class MediaGalleryViewController: UIViewController {
  struct Actions {
    var showInChat: ((MediaGalleryItem) -> Void)?
    var forward: ((MediaGalleryItem) -> Void)?
    /// Deletes the item's message. The gallery confirms first.
    var delete: ((MediaGalleryItem) -> Void)?
    var canDelete: (MediaGalleryItem) -> Bool = { $0.message?.out == true }
  }

  // MARK: - State

  private let source: MediaGallerySource
  private let actions: Actions
  private let sourceViewProvider: (MediaGalleryItem) -> UIView?
  private let openingItemID: Int64
  private let openingImage: UIImage?
  private let sourceCornerRadius: CGFloat
  var onDismiss: (() -> Void)?

  private var items: [MediaGalleryItem]
  private var currentIndex: Int
  private var chromeVisible = true
  private var didAnimateIn = false
  private var isTransitioning = true
  private var isDismissing = false
  private var isDismissPanning = false
  private var isApplyingSource = false
  private var needsSourceApply = false
  private var didFinish = false

  private var player: MediaGalleryVideoPlayer?
  private var playerItemID: Int64?
  private var resumeAfterScrub = false
  private var wasPlaying = false
  /// The rate to return to when a press-and-hold speed-up ends.
  private var rateBeforeHold: Float?
  private var chromeHideWork: DispatchWorkItem?
  /// Where long videos were left, by message, for the rest of the app session.
  private static var videoPositions: [Int64: Double] = [:]

  private weak var suppressedSourceView: UIView?
  private var suppressedSourceAlpha: CGFloat = 1

  private let pageGap: CGFloat = 20
  private let prefetcher = Nuke.ImagePrefetcher()
  private var prefetchedRequests: [URL: ImageRequest] = [:]
  private var isStripScrubbing = false
  private weak var openingHero: UIImageView?
  private var openingAnimator: UIViewPropertyAnimator?
  private var backdropAnimator: UIViewPropertyAnimator?

  // MARK: - Views

  private let backgroundView = UIView()
  private let pagerLayout = MediaGalleryPagerLayout()
  private lazy var pager = UICollectionView(frame: .zero, collectionViewLayout: pagerLayout)
  private let topBar = MediaGalleryTopBar()
  private let bottomBar = MediaGalleryBottomBar()
  private let toastView = MediaGalleryToastView()
  private var isPreparingShare = false
  /// The item whose share, copy or save waits for its download; its page shows the ring.
  private var waitingItemID: Int64?
  private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))

  // MARK: - Init

  init(
    source: MediaGallerySource,
    initialItemID: Int64,
    sourceImage: UIImage?,
    sourceCornerRadius: CGFloat = 16,
    actions: Actions = Actions(),
    sourceViewProvider: @escaping (MediaGalleryItem) -> UIView?
  ) {
    self.source = source
    self.actions = actions
    self.sourceViewProvider = sourceViewProvider
    openingItemID = initialItemID
    openingImage = sourceImage
    self.sourceCornerRadius = max(0, sourceCornerRadius)
    items = source.items
    currentIndex = source.items.firstIndex { $0.id == initialItemID } ?? 0
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalPresentationCapturesStatusBarAppearance = true
  }

  /// A single photo, such as an avatar or an attachment.
  convenience init(
    imageURL: URL,
    sourceView: UIView,
    sourceImage: UIImage? = nil,
    sourceCornerRadius: CGFloat = 16,
    showInChatAction: (() -> Void)? = nil
  ) {
    let item = MediaGalleryItem.photo(url: imageURL)
    self.init(
      source: StaticMediaGallerySource(items: [item]),
      initialItemID: item.id,
      sourceImage: sourceImage,
      sourceCornerRadius: sourceCornerRadius,
      actions: Actions(showInChat: showInChatAction.map { action in { _ in action() } }, canDelete: { _ in false }),
      sourceViewProvider: { [weak sourceView] _ in sourceView }
    )
  }

  /// A single video.
  convenience init(
    videoURL: URL,
    sourceView: UIView,
    sourceImage: UIImage? = nil,
    sourceCornerRadius: CGFloat = 16,
    showInChatAction: (() -> Void)? = nil
  ) {
    let item = MediaGalleryItem.video(url: videoURL)
    self.init(
      source: StaticMediaGallerySource(items: [item]),
      initialItemID: item.id,
      sourceImage: sourceImage,
      sourceCornerRadius: sourceCornerRadius,
      actions: Actions(showInChat: showInChatAction.map { action in { _ in action() } }, canDelete: { _ in false }),
      sourceViewProvider: { [weak sourceView] _ in sourceView }
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var prefersStatusBarHidden: Bool {
    !chromeVisible
  }

  override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
    .fade
  }

  private var currentItem: MediaGalleryItem? {
    items.indices.contains(currentIndex) ? items[currentIndex] : nil
  }

  private var pageWidth: CGFloat {
    pager.bounds.width
  }

  private var currentCell: MediaGalleryPageCell? {
    pager.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? MediaGalleryPageCell
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    backgroundView.backgroundColor = backgroundColor
    backgroundView.alpha = 0
    backgroundView.frame = view.bounds
    backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(backgroundView)

    pagerLayout.scrollDirection = .horizontal
    pagerLayout.minimumLineSpacing = 0
    pagerLayout.minimumInteritemSpacing = 0
    pager.backgroundColor = .clear
    pager.isPagingEnabled = true
    pager.showsHorizontalScrollIndicator = false
    pager.contentInsetAdjustmentBehavior = .never
    pager.alwaysBounceVertical = false
    pager.dataSource = self
    pager.delegate = self
    pager.isHidden = true
    pager.register(MediaGalleryPageCell.self, forCellWithReuseIdentifier: MediaGalleryPageCell.reuseIdentifier)
    view.addSubview(pager)

    view.addSubview(topBar)
    view.addSubview(bottomBar)
    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: view.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    topBar.alpha = 0
    bottomBar.alpha = 0

    toastView.alpha = 0
    view.addSubview(toastView)

    wireActions()

    dismissPan.delegate = self
    dismissPan.maximumNumberOfTouches = 1
    view.addGestureRecognizer(dismissPan)

    source.onChange = { [weak self] in self?.sourceDidChange() }
    source.onLinksRefreshed = { [weak self] ids in self?.linksDidRefresh(ids) }
    source.start()
    source.pageDidChange(to: currentIndex)
    updateChrome()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let frame = CGRect(x: 0, y: 0, width: view.bounds.width + pageGap, height: view.bounds.height)
    guard pager.frame != frame else { return }
    // A rotation or window resize clamps the old offset against the new content size, which
    // scrolls. Suppress that, or the page would read from the stale offset and jump.
    isApplyingSource = true
    pager.frame = frame
    pagerLayout.itemSize = frame.size
    pagerLayout.invalidateLayout()
    pager.layoutIfNeeded()
    // Not `contentOffset =`: a paging scroll view starts an animated snap from the clamped
    // offset, and only the non-animated setter cancels it.
    pager.setContentOffset(CGPoint(x: CGFloat(currentIndex) * frame.width, y: 0), animated: false)
    isApplyingSource = false
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Takes focus from the composer so its keyboard doesn't stay over the gallery, and
    // receives hardware-keyboard commands.
    becomeFirstResponder()
  }

  override var canBecomeFirstResponder: Bool {
    true
  }

  override var prefersHomeIndicatorAutoHidden: Bool {
    !chromeVisible
  }

  override var keyCommands: [UIKeyCommand]? {
    var commands = [
      UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFromKeyboard)),
      UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(showPreviousFromKeyboard)),
      UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(showNextFromKeyboard)),
    ]
    if currentItem?.kind == .video {
      commands.append(UIKeyCommand(input: " ", modifierFlags: [], action: #selector(togglePlaybackFromKeyboard)))
      commands.append(UIKeyCommand(input: "m", modifierFlags: [], action: #selector(toggleMuteFromKeyboard)))
      commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .shift, action: #selector(skipBackFromKeyboard)))
      commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .shift, action: #selector(skipForwardFromKeyboard)))
    }
    if let item = currentItem, canDelete(item) {
      commands.append(UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(deleteFromKeyboard)))
    }
    for command in commands {
      command.wantsPriorityOverSystemBehavior = true
    }
    return commands
  }

  @objc private func closeFromKeyboard() {
    animateOut()
  }

  @objc private func showPreviousFromKeyboard() {
    guard !isTransitioning, !isDismissPanning else { return }
    scrollToItem(at: currentIndex - 1, animated: true)
  }

  @objc private func showNextFromKeyboard() {
    guard !isTransitioning, !isDismissPanning else { return }
    scrollToItem(at: currentIndex + 1, animated: true)
  }

  @objc private func togglePlaybackFromKeyboard() {
    toggleVideoPlayback()
  }

  @objc private func deleteFromKeyboard() {
    guard let item = currentItem, canDelete(item), presentedViewController == nil else { return }
    confirmDelete(item)
  }

  @objc private func toggleMuteFromKeyboard() {
    toggleMute()
  }

  @objc private func skipBackFromKeyboard() {
    currentPlayer?.skip(by: -5)
  }

  @objc private func skipForwardFromKeyboard() {
    currentPlayer?.skip(by: 5)
  }

  override func accessibilityPerformEscape() -> Bool {
    animateOut()
    return true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    guard !didAnimateIn else { return }
    didAnimateIn = true
    view.layoutIfNeeded()
    animateIn()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed {
      cleanUp()
    }
  }

  private func cleanUp() {
    guard !didFinish else { return }
    didFinish = true
    toastHideWork?.cancel()
    stopVideo()
    prefetcher.stopPrefetching()
    source.stop()
    restoreSuppressedSource()
    onDismiss?()
  }

  // MARK: - Transitions

  private func makeHero(image: UIImage, frame: CGRect, cornerRadius: CGFloat) -> UIImageView {
    let hero = UIImageView(image: image)
    hero.contentMode = .scaleAspectFill
    hero.clipsToBounds = true
    hero.layer.cornerCurve = .continuous
    hero.layer.cornerRadius = cornerRadius
    hero.frame = frame
    hero.isUserInteractionEnabled = false
    return hero
  }

  private func cornerRadius(for sourceView: UIView) -> CGFloat {
    let radius = max(sourceView.layer.cornerRadius, sourceCornerRadius)
    return min(radius, min(sourceView.bounds.width, sourceView.bounds.height) / 2)
  }

  private func fittedFrame(for size: CGSize?) -> CGRect {
    let bounds = view.bounds
    guard let size, size.width > 0, size.height > 0 else { return bounds }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
      x: (bounds.width - fitted.width) / 2,
      y: (bounds.height - fitted.height) / 2,
      width: fitted.width,
      height: fitted.height
    )
  }

  private func animateIn() {
    pager.layoutIfNeeded()
    let item = currentItem
    let cell = currentCell
    cell?.layoutIfNeeded()
    // The page's own decode, when it's already in memory, is sharper than the bubble's.
    let image = (cell?.hasFullImage == true ? cell?.imageView.image : nil)
      ?? openingImage
      ?? cell?.imageView.image
    let sourceView = item.flatMap(sourceViewProvider)

    guard let image, let sourceView, sourceView.window != nil else {
      pager.isHidden = false
      pager.alpha = 0
      let animator = UIViewPropertyAnimator(duration: 0.22, curve: .easeOut) {
        self.pager.alpha = 1
        self.backgroundView.alpha = 1
        self.applyChromeAlpha()
      }
      animator.addCompletion { _ in self.didFinishAppearing() }
      openingAnimator = animator
      animator.startAnimation()
      return
    }

    let from = sourceView.convert(sourceView.bounds, to: view)
    // Lands exactly where the page lays the media out, so the hand-off doesn't jump.
    let to = cell.map { $0.convert($0.fittedRect(), to: view) }
      ?? fittedFrame(for: item?.pixelSize ?? image.size)
    let hero = makeHero(image: image, frame: from, cornerRadius: cornerRadius(for: sourceView))
    view.insertSubview(hero, belowSubview: topBar)
    openingHero = hero
    suppress(sourceView)

    // A fixed-length spring: it ends on time instead of settling for another few hundred
    // milliseconds, which made the open feel slow.
    let animator = UIViewPropertyAnimator(duration: Self.openDuration, dampingRatio: 0.9) {
      hero.frame = to
      hero.layer.cornerRadius = 0
    }
    animator.addCompletion { [weak self] _ in
      guard let self else { return }
      openingAnimator = nil
      // Closed before the morph landed; the close animation owns the hero now.
      guard !isDismissing else { return }
      pager.isHidden = false
      openingHero = nil
      if let shown = currentCell?.imageView.image, shown !== hero.image {
        // The page shows a different decode of the same photo; fade between them.
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
          hero.alpha = 0
        } completion: { _ in
          hero.removeFromSuperview()
        }
      } else {
        hero.removeFromSuperview()
      }
      didFinishAppearing()
    }
    openingAnimator = animator
    animator.startAnimation()

    // The backdrop and bars arrive ahead of the morph, like Photos.
    let backdrop = UIViewPropertyAnimator(duration: Self.openDuration * 0.7, curve: .easeOut) {
      self.backgroundView.alpha = 1
      self.applyChromeAlpha()
    }
    backdropAnimator = backdrop
    backdrop.startAnimation()
  }

  private static let openDuration: TimeInterval = 0.32
  private static let closeDuration: TimeInterval = 0.3

  private func didFinishAppearing() {
    guard !isDismissing else { return }
    isTransitioning = false
    startVideoIfNeeded(autoplay: true)
    prefetchNeighbors()
    if needsSourceApply { applySource() }
  }

  /// Flies the current item back to its thumbnail, or off screen when the thumbnail
  /// isn't visible. A close during the open reverses the morph from where it is.
  private func animateOut(velocity: CGPoint = .zero) {
    guard !isDismissing else { return }
    isDismissing = true
    isTransitioning = true
    resignFirstResponder()
    chromeHideWork?.cancel()

    let hero: UIImageView
    let fromFrame: CGRect
    if let opening = openingHero, let animator = openingAnimator, animator.state == .active {
      // Leaves the hero and backdrop where they are on screen.
      animator.stopAnimation(true)
      openingAnimator = nil
      if backdropAnimator?.state == .active { backdropAnimator?.stopAnimation(true) }
      backdropAnimator = nil
      openingHero = nil
      stopVideo()
      hero = opening
      fromFrame = opening.frame
    } else {
      if openingAnimator?.state == .active { openingAnimator?.stopAnimation(true) }
      openingAnimator = nil
      if backdropAnimator?.state == .active { backdropAnimator?.stopAnimation(true) }
      backdropAnimator = nil
      openingHero?.removeFromSuperview()
      openingHero = nil
      let cell = currentCell
      // A played video flies back on its current frame, not its poster.
      let image = cell?.displayedImage()
      let frame = cell.map { $0.imageView.convert($0.imageView.bounds, to: view) }
      stopVideo()

      guard let image, let frame, frame.width > 0, frame.height > 0 else {
        UIView.animate(withDuration: 0.2) {
          self.view.alpha = 0
        } completion: { _ in
          self.finishDismiss()
        }
        return
      }
      hero = makeHero(image: image, frame: frame, cornerRadius: 0)
      view.insertSubview(hero, belowSubview: topBar)
      fromFrame = frame
    }
    pager.isHidden = true

    let target = currentItem.flatMap(sourceViewProvider).flatMap { $0.window == nil ? nil : $0 }
    if let target {
      let targetFrame = target.convert(target.bounds, to: view)
      if view.bounds.intersects(targetFrame), targetFrame.width > 1 {
        suppress(target)
        let radius = cornerRadius(for: target)
        // The drag's speed toward the thumbnail carries into the spring; a flick away from it
        // doesn't make the return faster.
        let dx = targetFrame.midX - fromFrame.midX
        let dy = targetFrame.midY - fromFrame.midY
        let distance = max(1, hypot(dx, dy))
        let toward = (velocity.x * dx + velocity.y * dy) / distance
        let relative = min(max(0, toward / distance), 8)
        let timing = UISpringTimingParameters(
          dampingRatio: 1,
          initialVelocity: CGVector(dx: relative, dy: relative)
        )
        let animator = UIViewPropertyAnimator(duration: Self.closeDuration, timingParameters: timing)
        animator.addAnimations {
          hero.frame = targetFrame
          hero.layer.cornerRadius = radius
          self.backgroundView.alpha = 0
          self.topBar.alpha = 0
          self.bottomBar.alpha = 0
        }
        animator.addCompletion { _ in
          self.restoreSuppressedSource()
          hero.removeFromSuperview()
          self.finishDismiss()
        }
        animator.startAnimation()
        return
      }
    }

    let reference = velocity.y != 0 ? velocity.y : fromFrame.midY - view.bounds.midY
    let direction: CGFloat = reference >= 0 ? 1 : -1
    UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseIn) {
      hero.frame = fromFrame.offsetBy(dx: velocity.x * 0.05, dy: direction * self.view.bounds.height * 0.6)
      hero.alpha = 0
      self.backgroundView.alpha = 0
      self.topBar.alpha = 0
      self.bottomBar.alpha = 0
    } completion: { _ in
      hero.removeFromSuperview()
      self.finishDismiss()
    }
  }

  private func finishDismiss() {
    restoreSuppressedSource()
    dismiss(animated: false) { [weak self] in
      self?.cleanUp()
    }
  }

  func dismissGallery() {
    animateOut()
  }

  // MARK: - Source thumbnail visibility

  /// Hides the thumbnail behind the current item so it doesn't show twice while dragging.
  private func suppress(_ sourceView: UIView) {
    let target = Self.visibilityTarget(for: sourceView)
    guard target !== suppressedSourceView else { return }
    restoreSuppressedSource()
    suppressedSourceView = target
    suppressedSourceAlpha = target.alpha
    target.alpha = 0
  }

  private func restoreSuppressedSource() {
    guard let view = suppressedSourceView else { return }
    view.alpha = suppressedSourceAlpha
    suppressedSourceView = nil
  }

  private func suppressCurrentSource() {
    guard let item = currentItem, let view = sourceViewProvider(item), view.window != nil else {
      restoreSuppressedSource()
      return
    }
    suppress(view)
  }

  /// Bubble media views fade as a whole, not just their inner image view.
  private static func visibilityTarget(for sourceView: UIView) -> UIView {
    if sourceView is NewPhotoView || sourceView is NewVideoView {
      return sourceView
    }
    if let parent = sourceView.superview, parent is NewPhotoView || parent is NewVideoView {
      return parent
    }
    return sourceView
  }

  // MARK: - Source updates

  private func sourceDidChange() {
    let busy = pager.isTracking || pager.isDragging || pager.isDecelerating || isDismissPanning
      || isTransitioning || isStripScrubbing || currentCell?.isZoomed == true
    if busy {
      needsSourceApply = true
      updateChrome()
      return
    }
    applySource()
  }

  /// Applies new items, keeping the current item on screen when older pages are prepended.
  private func applySource() {
    needsSourceApply = false
    let next = source.items
    guard !next.isEmpty else {
      animateOut()
      return
    }
    guard next != items else {
      updateChrome()
      return
    }

    let currentID = currentItem?.id
    let previous = items
    let nextIndex = currentID.flatMap { id in next.firstIndex { $0.id == id } } ?? min(currentIndex, next.count - 1)

    isApplyingSource = true
    UIView.performWithoutAnimation {
      updatePages(from: previous, to: next)
      currentIndex = nextIndex
      pager.layoutIfNeeded()
      pager.setContentOffset(CGPoint(x: CGFloat(currentIndex) * pageWidth, y: 0), animated: false)
      pager.layoutIfNeeded()
    }
    isApplyingSource = false

    source.pageDidChange(to: currentIndex)
    if currentItem?.id != playerItemID {
      stopVideo()
    } else if let player, player.stream == nil, let item = currentItem, Self.playableURL(for: item) != player.url {
      // Fresh links arrived for the video on screen. A native stream needs no link, and keeps
      // playing when its download lands on disk.
      let wasPlaying = player.isPlaying
      stopVideo()
      startVideoIfNeeded(autoplay: wasPlaying)
    } else if let player {
      currentCell?.attach(player: player)
    }
    updateChrome()
    prefetchNeighbors()
  }

  /// Inserts and removes only the pages that changed, so the pages on screen keep their cells:
  /// a reload re-dequeued every page, dropping images back to placeholders and the playing
  /// video's layer back to its poster.
  private func updatePages(from previous: [MediaGalleryItem], to next: [MediaGalleryItem]) {
    let oldIDs = previous.map(\.id)
    let newIDs = next.map(\.id)
    guard pager.window != nil, pageWidth > 0, pager.numberOfSections == 1,
          pager.numberOfItems(inSection: 0) == previous.count
    else {
      items = next
      pager.reloadData()
      return
    }
    if oldIDs != newIDs {
      let difference = newIDs.difference(from: oldIDs)
      // The update lands on the current page's new offset, so its cell stays on screen through
      // it instead of being recycled at the old offset.
      pagerLayout.pinnedIndex = currentItem.flatMap { item in newIDs.firstIndex(of: item.id) }
      defer { pagerLayout.pinnedIndex = nil }
      pager.performBatchUpdates {
        items = next
        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        for change in difference {
          switch change {
            case let .remove(offset, _, _): deletions.append(IndexPath(item: offset, section: 0))
            case let .insert(offset, _, _): insertions.append(IndexPath(item: offset, section: 0))
          }
        }
        pager.deleteItems(at: deletions)
        pager.insertItems(at: insertions)
      }
    } else {
      items = next
    }
    // Same pages with new details (a landed download, a fresh link, an edited caption).
    let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    let changed = pager.indexPathsForVisibleItems.filter { indexPath in
      guard next.indices.contains(indexPath.item) else { return false }
      let item = next[indexPath.item]
      return oldByID[item.id].map { $0 != item } ?? false
    }
    if !changed.isEmpty {
      pager.reconfigureItems(at: changed)
    }
  }

  /// Pages that failed on an expired link try again once fresh links are saved.
  private func linksDidRefresh(_ ids: Set<Int64>) {
    if needsSourceApply, !pager.isDragging, !pager.isDecelerating, !isDismissPanning, !isTransitioning {
      applySource()
    }
    for case let cell as MediaGalleryPageCell in pager.visibleCells {
      guard let id = cell.item?.id, ids.contains(id) else { continue }
      cell.freshLinksArrived()
    }
  }

  // MARK: - Paging

  private func currentIndexDidChange() {
    source.pageDidChange(to: currentIndex)
    if currentItem?.id != playerItemID {
      stopVideo()
    }
    updateChrome(animated: true)
    // Warm the next pages as soon as the swipe passes halfway, not once it settles, so a quick
    // run of swipes doesn't outpace the decodes.
    if !isStripScrubbing { prefetchNeighbors() }
  }

  private func pageDidSettle() {
    // Scrubbing the strip passes through many pages; settle once it lets go, so passing a
    // video doesn't start its player and download.
    guard !isStripScrubbing else { return }
    for case let cell as MediaGalleryPageCell in pager.visibleCells where cell.item?.id != currentItem?.id {
      cell.resetZoom(animated: false)
    }
    startVideoIfNeeded(autoplay: true)
    prefetchNeighbors()
    if needsSourceApply { applySource() }
  }

  private func scrollToItem(at index: Int, animated: Bool = false) {
    guard items.indices.contains(index), index != currentIndex else { return }
    // Animated scrolls settle in `scrollViewDidEndScrollingAnimation`.
    pager.setContentOffset(CGPoint(x: CGFloat(index) * pageWidth, y: 0), animated: animated)
    if !animated { pageDidSettle() }
  }

  private var displayScale: CGFloat {
    let scale = traitCollection.displayScale
    return scale > 0 ? scale : 3
  }

  /// Warms the pages next to the current one with the same page-sized requests the pages make,
  /// and drops warming that's no longer near.
  private func prefetchNeighbors() {
    guard !items.isEmpty, view.bounds.width > 0 else { return }
    let range = max(0, currentIndex - 2) ... min(items.count - 1, currentIndex + 2)
    var requests: [URL: ImageRequest] = [:]
    for item in items[range] {
      switch item.kind {
        case .photo:
          guard let url = item.mediaURL else { continue }
          requests[url] = MediaGalleryImageRequests.display(
            url: url, item: item, pageSize: view.bounds.size, scale: displayScale
          )
        case .video:
          guard let url = item.thumbnailURL else { continue }
          requests[url] = ImageRequest(url: url)
      }
    }
    let stale = prefetchedRequests.filter { requests[$0.key] == nil }
    if !stale.isEmpty {
      prefetcher.stopPrefetching(with: Array(stale.values))
    }
    prefetchedRequests = requests
    prefetcher.startPrefetching(with: Array(requests.values))
  }

  // MARK: - Chrome

  private func applyChromeAlpha() {
    topBar.alpha = chromeVisible ? 1 : 0
    bottomBar.alpha = chromeVisible ? 1 : 0
    topBar.isUserInteractionEnabled = chromeVisible
    bottomBar.isUserInteractionEnabled = chromeVisible
  }

  /// White behind the chrome; black when the chrome is hidden, like Photos.
  private var backgroundColor: UIColor {
    chromeVisible ? .systemBackground : .black
  }

  private func setChromeVisible(_ visible: Bool) {
    guard chromeVisible != visible else { return }
    chromeVisible = visible
    UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.applyChromeAlpha()
      self.backgroundView.backgroundColor = self.backgroundColor
      self.setNeedsStatusBarAppearanceUpdate()
    }
    setNeedsUpdateOfHomeIndicatorAutoHidden()
    if visible { scheduleChromeAutoHide() } else { chromeHideWork?.cancel() }
  }

  /// Like Telegram, the chrome steps aside after a few seconds of video playback.
  private func scheduleChromeAutoHide() {
    chromeHideWork?.cancel()
    guard chromeVisible, let player = currentPlayer, player.isPlaying else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, chromeVisible, let player = currentPlayer, player.isPlaying, !player.isBuffering,
            !bottomBar.videoControls.isScrubbing, !isStripScrubbing, !isDismissPanning, presentedViewController == nil
      else { return }
      setChromeVisible(false)
    }
    chromeHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
  }

  /// The player, when it belongs to the page on screen.
  private var currentPlayer: MediaGalleryVideoPlayer? {
    guard let player, playerItemID == currentItem?.id else { return nil }
    return player
  }

  private func updateChrome(animated: Bool = false) {
    guard let item = currentItem else { return }
    let message = item.message
    topBar.update(
      title: Self.senderName(message),
      subtitle: message.map { Self.dateText($0.date) },
      animated: animated
    )
    topBar.menuButton.menu = makeMenu(for: item)
    topBar.menuButton.isHidden = topBar.menuButton.menu?.children.isEmpty ?? true

    let counter = source.position(at: currentIndex).flatMap { position in
      position.total > 1
        ? String(
          format: NSLocalizedString("%@ of %@", comment: "Gallery position: item of total"),
          position.index.formatted(),
          position.total.formatted()
        )
        : nil
    }
    bottomBar.update(caption: message?.text, counter: counter, isVideo: item.kind == .video, animated: animated)
    bottomBar.setStripVisible(items.count > 1, animated: didAnimateIn)
    bottomBar.strip.update(items: items, currentIndex: currentIndex, animated: true)
    updateVideoControls()
  }

  private func canDelete(_ item: MediaGalleryItem) -> Bool {
    actions.delete != nil && item.message != nil && actions.canDelete(item)
  }

  private static func senderName(_ message: Message?) -> String? {
    guard let message else { return nil }
    if message.out == true {
      return NSLocalizedString("You", comment: "Gallery sender for your own message")
    }
    return ObjectCache.shared.getUser(id: message.fromId)?.user.displayName
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  private static let yearDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("yMMMd")
    return formatter
  }()

  static func dateText(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = timeFormatter.string(from: date)
    let day: String
    if calendar.isDateInToday(date) {
      day = NSLocalizedString("Today", comment: "Gallery date")
    } else if calendar.isDateInYesterday(date) {
      day = NSLocalizedString("Yesterday", comment: "Gallery date")
    } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
      day = dayFormatter.string(from: date)
    } else {
      day = yearDayFormatter.string(from: date)
    }
    return String(format: NSLocalizedString("%@ at %@", comment: "Gallery date: day at time"), day, time)
  }

  private static func rateTitle(_ rate: Float) -> String {
    rate == 1
      ? NSLocalizedString("Normal", comment: "Gallery video playback speed")
      : "\(rate.formatted(.number.precision(.fractionLength(0 ... 2))))×"
  }

  private func setRate(_ rate: Float) {
    if let player = currentPlayer {
      player.rate = rate
    } else {
      MediaGalleryVideoPlayer.preferredRate = rate
    }
    if let item = currentItem {
      topBar.menuButton.menu = makeMenu(for: item)
    }
  }

  private func toggleMute() {
    guard currentItem?.kind == .video else { return }
    if let player = currentPlayer {
      player.isMuted.toggle()
    } else {
      MediaGalleryVideoPlayer.prefersMuted.toggle()
    }
    updateVideoControls()
  }

  private func makeMenu(for item: MediaGalleryItem) -> UIMenu {
    var children: [UIMenuElement] = []
    if item.kind == .video {
      let current = currentPlayer?.rate ?? MediaGalleryVideoPlayer.preferredRate
      let speeds = MediaGalleryVideoPlayer.rates.map { rate in
        UIAction(title: Self.rateTitle(rate), state: rate == current ? .on : .off) { [weak self] _ in
          self?.setRate(rate)
        }
      }
      let speed = UIMenu(
        title: NSLocalizedString("Playback Speed", comment: "Gallery video menu"),
        subtitle: Self.rateTitle(current),
        image: UIImage(systemName: "gauge.with.dots.needle.50percent"),
        options: .singleSelection,
        children: speeds
      )
      children.append(UIMenu(options: .displayInline, children: [speed]))
    }
    if let showInChat = actions.showInChat {
      children.append(UIAction(title: "Show in Chat", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
        self?.performAfterDismiss { showInChat(item) }
      })
    }
    children.append(UIAction(
      title: item.kind == .video ? "Save Video" : "Save to Photos",
      image: UIImage(systemName: "arrow.down.to.line")
    ) { [weak self] _ in self?.save(item) })
    if item.kind == .photo {
      children.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
        self?.copy(item)
      })
    }
    children.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
      self?.share(item)
    })
    if actions.forward != nil, item.message != nil {
      children.append(UIAction(title: "Forward", image: UIImage(systemName: "arrowshape.turn.up.right")) { [weak self] _ in
        self?.forward(item)
      })
    }
    if canDelete(item) {
      children.append(UIMenu(options: .displayInline, children: [
        UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
          self?.confirmDelete(item)
        },
      ]))
    }
    return UIMenu(children: children)
  }

  private func wireActions() {
    topBar.closeButton.addAction(UIAction { [weak self] _ in self?.animateOut() }, for: .touchUpInside)
    bottomBar.shareButton.addAction(UIAction { [weak self] _ in
      guard let self, let item = currentItem else { return }
      share(item)
    }, for: .touchUpInside)
    bottomBar.strip.onSelect = { [weak self] index in
      self?.scrollToItem(at: index)
    }
    bottomBar.strip.onScrubChange = { [weak self] scrubbing in
      guard let self else { return }
      isStripScrubbing = scrubbing
      if !scrubbing { pageDidSettle() }
    }

    let controls = bottomBar.videoControls
    controls.playButton.addAction(UIAction { [weak self] _ in self?.toggleVideoPlayback() }, for: .touchUpInside)
    controls.muteButton.addAction(UIAction { [weak self] _ in self?.toggleMute() }, for: .touchUpInside)
    controls.onSeek = { [weak self] fraction, exact in self?.player?.seek(to: fraction, exact: exact) }
    controls.onScrubChange = { [weak self] scrubbing in
      guard let self, let player else { return }
      if scrubbing {
        chromeHideWork?.cancel()
        resumeAfterScrub = player.isPlaying
        player.pause()
      } else if resumeAfterScrub {
        player.play()
      }
    }
  }

  // MARK: - Actions

  private func performAfterDismiss(_ action: @escaping () -> Void) {
    let previous = onDismiss
    onDismiss = {
      previous?()
      action()
    }
    animateOut()
  }

  private func forward(_ item: MediaGalleryItem) {
    guard let forward = actions.forward else { return }
    performAfterDismiss { forward(item) }
  }

  private func confirmDelete(_ item: MediaGalleryItem) {
    guard let delete = actions.delete else { return }
    let alert = UIAlertController(
      title: item.kind == .video ? "Delete Video" : "Delete Photo",
      message: "This deletes the message for everyone in the chat.",
      preferredStyle: .actionSheet
    )
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      delete(item)
      self?.source.remove(id: item.id)
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.popoverPresentationController?.sourceView = topBar.menuButton
    alert.popoverPresentationController?.sourceRect = topBar.menuButton.bounds
    present(alert, animated: true)
  }

  private func copy(_ item: MediaGalleryItem) {
    Task {
      let image = await fullImage(for: item)
      guard let image else {
        showToast("Couldn't copy the photo", systemImage: "exclamationmark.triangle")
        return
      }
      UIPasteboard.general.image = image
      showToast("Copied", systemImage: "doc.on.doc")
    }
  }

  private func share(_ item: MediaGalleryItem) {
    guard !isPreparingShare else { return }
    isPreparingShare = true
    Task {
      defer { isPreparingShare = false }
      let activityItem: Any?
      switch item.kind {
        case .photo:
          // The original file keeps its format and metadata; a decoded image would be re-encoded.
          if let file = Self.existingFile(item.mediaURL) {
            activityItem = file
          } else {
            // A photo that isn't on disk yet downloads first, with the page's ring showing it.
            activityItem = await fullImage(for: item)
          }
        case .video:
          activityItem = try? await localVideoURL(for: item)
      }
      // Swiped on while it downloaded: a sheet for a page no longer on screen would surprise.
      guard !didFinish, !isDismissing, currentItem?.id == item.id else { return }
      guard let activityItem else {
        showToast("Couldn't load this item", systemImage: "exclamationmark.triangle")
        return
      }
      hideToast()
      let controller = UIActivityViewController(activityItems: [activityItem], applicationActivities: nil)
      controller.popoverPresentationController?.sourceView = bottomBar.shareButton
      controller.popoverPresentationController?.sourceRect = bottomBar.shareButton.bounds
      present(controller, animated: true)
    }
  }

  private func save(_ item: MediaGalleryItem) {
    Task {
      let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
      guard status == .authorized || status == .limited else {
        showToast("Allow photo access in Settings", systemImage: "lock")
        return
      }
      do {
        switch item.kind {
          case .photo:
            if let file = Self.existingFile(item.mediaURL) {
              try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
              }
            } else {
              guard let image = await fullImage(for: item) else { throw MediaGalleryError.unavailable }
              try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
              }
            }
          case .video:
            let url = try await localVideoURL(for: item)
            try await PHPhotoLibrary.shared().performChanges {
              _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToast(item.kind == .video ? "Video saved" : "Saved to Photos", systemImage: "checkmark")
      } catch {
        Log.shared.error("Gallery failed to save media", error: error)
        showToast("Couldn't save", systemImage: "exclamationmark.triangle")
      }
    }
  }

  private static func existingFile(_ url: URL?) -> URL? {
    guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  /// The original photo, for copy, share or save. A download shows on the page's ring.
  private func fullImage(for item: MediaGalleryItem) async -> UIImage? {
    beginWaiting(for: item)
    var image: UIImage?
    for url in [item.mediaURL, item.fallbackURL].compactMap({ $0 }) {
      // A one-off full decode; keep it out of the memory cache.
      image = await loadImage(ImageRequest(url: url, options: [.disableMemoryCacheWrites]), for: item)
      if image != nil { break }
    }
    endWaiting(for: item, finished: image != nil)
    return image
  }

  private func loadImage(_ request: ImageRequest, for item: MediaGalleryItem) async -> UIImage? {
    await withCheckedContinuation { continuation in
      _ = ImagePipeline.shared.loadImage(with: request, progress: { [weak self] _, completed, total in
        MainActor.assumeIsolated {
          guard total > 0 else { return }
          self?.updateWaiting(Double(completed) / Double(total), for: item)
        }
      }) { result in
        continuation.resume(returning: try? result.get().image)
      }
    }
  }

  // MARK: - Waiting for a download

  private func pageCell(for id: Int64) -> MediaGalleryPageCell? {
    pager.visibleCells.lazy.compactMap { $0 as? MediaGalleryPageCell }.first { $0.item?.id == id }
  }

  private func beginWaiting(for item: MediaGalleryItem) {
    if let previous = waitingItemID, previous != item.id {
      pageCell(for: previous)?.setWaitingForOriginal(false, finished: false)
    }
    waitingItemID = item.id
    pageCell(for: item.id)?.setWaitingForOriginal(true)
  }

  private func updateWaiting(_ fraction: Double, for item: MediaGalleryItem) {
    guard waitingItemID == item.id else { return }
    pageCell(for: item.id)?.setWaitingProgress(fraction)
  }

  private func endWaiting(for item: MediaGalleryItem, finished: Bool) {
    guard waitingItemID == item.id else { return }
    waitingItemID = nil
    pageCell(for: item.id)?.setWaitingForOriginal(false, finished: finished)
  }

  /// The video on disk. A chat video that isn't there yet joins its native download, the same
  /// one the player streams from and the chat keeps, instead of fetching a second copy.
  private func localVideoURL(for item: MediaGalleryItem) async throws -> URL {
    if let url = Self.existingFile(item.mediaURL) {
      return url
    }
    if let video = item.video, let message = item.message {
      beginWaiting(for: item)
      let progress = FileDownloader.shared.videoProgressPublisher(videoId: video.id)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] progress in
          MainActor.assumeIsolated { self?.updateWaiting(progress.progress, for: item) }
        }
      do {
        let url = try await withCheckedThrowingContinuation { continuation in
          FileDownloader.shared.downloadVideo(video: video, for: message, priority: .userInitiated) { result in
            continuation.resume(with: result)
          }
        }
        progress.cancel()
        endWaiting(for: item, finished: true)
        return url
      } catch {
        progress.cancel()
        endWaiting(for: item, finished: false)
        throw error
      }
    }
    guard let remote = [item.mediaURL, item.fallbackURL].compactMap({ $0 }).first(where: { !$0.isFileURL }) else {
      throw MediaGalleryError.unavailable
    }
    beginWaiting(for: item)
    let downloaded: URL
    do {
      (downloaded, _) = try await URLSession.shared.download(from: remote)
      endWaiting(for: item, finished: true)
    } catch {
      endWaiting(for: item, finished: false)
      throw error
    }
    let ext = remote.pathExtension.isEmpty ? "mp4" : remote.pathExtension
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("Video")
      .appendingPathExtension(ext)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: downloaded, to: destination)
    return destination
  }

  private var toastHideWork: DispatchWorkItem?

  /// A short result under the top bar, such as "Saved to Photos". Downloads show on the page's
  /// ring instead.
  func showToast(_ text: String, systemImage: String) {
    guard !didFinish else { return }
    toastView.update(text: text, systemImage: systemImage)
    let size = toastView.systemLayoutSizeFitting(
      CGSize(width: view.bounds.width - 64, height: 40),
      withHorizontalFittingPriority: .fittingSizeLevel,
      verticalFittingPriority: .required
    )
    let width = min(size.width, view.bounds.width - 64)
    toastView.frame = CGRect(
      x: (view.bounds.width - width) / 2,
      y: max(topBar.frame.maxY, view.safeAreaInsets.top) + 8,
      width: width,
      height: 40
    )
    toastHideWork?.cancel()
    UIView.animate(withDuration: 0.2) { self.toastView.alpha = 1 }
    let work = DispatchWorkItem { [weak self] in self?.hideToast() }
    toastHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
  }

  private func hideToast() {
    toastHideWork?.cancel()
    toastHideWork = nil
    UIView.animate(withDuration: 0.25) { self.toastView.alpha = 0 }
  }

  // MARK: - Video

  private func startVideoIfNeeded(autoplay: Bool) {
    guard !isDismissing, let item = currentItem, item.kind == .video else { return }
    if let player, playerItemID == item.id {
      currentCell?.attach(player: player)
      return
    }
    guard let url = Self.playableURL(for: item) else { return }
    stopVideo()
    // A video that is not on disk plays from its native download, which the chat then keeps,
    // instead of streaming a second copy from the CDN.
    var stream: NativeVideoStream?
    if !url.isFileURL, let video = item.video, let message = item.message {
      stream = FileDownloader.shared.videoStream(video: video, for: message)
    }
    let knownDuration = Double(item.duration ?? 0)
    let player = MediaGalleryVideoPlayer(url: url, stream: stream, fallbackDuration: knownDuration)
    player.onUpdate = { [weak self] in self?.updateVideoControls() }
    // Short clips loop, as in Telegram; long videos pick up where they were left.
    player.loops = knownDuration > 0 && knownDuration <= Self.loopingDuration
    if item.message != nil, let position = Self.videoPositions[item.id] {
      player.seek(toSeconds: position)
    }
    self.player = player
    playerItemID = item.id
    wasPlaying = false
    currentCell?.attach(player: player)
    if autoplay {
      player.play()
    }
    updateVideoControls()
  }

  /// The current page's player, for device tests.
  var currentVideoPlayer: AVPlayer? {
    player?.player
  }

  /// The item on screen, for device tests.
  var visibleItemID: Int64? {
    currentItem?.id
  }

  /// The page on screen, for device tests.
  var visiblePageCell: MediaGalleryPageCell? {
    currentCell
  }

  /// Whether the bars are showing, for device tests.
  var isChromeVisible: Bool {
    chromeVisible
  }

  private static func playableURL(for item: MediaGalleryItem) -> URL? {
    if let url = item.mediaURL, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    return item.fallbackURL
  }

  /// Clips up to this long loop.
  private static let loopingDuration: Double = 30
  /// Videos at least this long skip from a double tap; shorter ones zoom.
  private static let skippableDuration: Double = 30
  /// Videos at least this long remember where they were left.
  private static let resumableDuration: Double = 20

  private func stopVideo() {
    guard let player else { return }
    rememberPosition(of: player)
    player.stop()
    self.player = nil
    playerItemID = nil
    rateBeforeHold = nil
    wasPlaying = false
    chromeHideWork?.cancel()
    for case let cell as MediaGalleryPageCell in pager.visibleCells {
      cell.detachPlayer()
    }
  }

  /// Keeps a long video's position when it's left mid-way; near either end, it starts over.
  private func rememberPosition(of player: MediaGalleryVideoPlayer) {
    guard let id = playerItemID, items.first(where: { $0.id == id })?.message != nil else { return }
    let duration = player.duration
    let time = player.currentTime
    if duration >= Self.resumableDuration, time > 5, time < duration - 5 {
      Self.videoPositions[id] = time
    } else {
      Self.videoPositions[id] = nil
    }
  }

  private func videoState(of player: MediaGalleryVideoPlayer) -> MediaGalleryPageCell.VideoState {
    MediaGalleryPageCell.VideoState(
      isPlaying: player.isPlaying,
      isBuffering: player.isBuffering,
      isFailed: player.isFailed,
      isAtEnd: player.isAtEnd
    )
  }

  private func toggleVideoPlayback() {
    if let player, playerItemID == currentItem?.id {
      player.togglePlayback()
    } else {
      startVideoIfNeeded(autoplay: true)
    }
  }

  private func updateVideoControls() {
    guard let item = currentItem, item.kind == .video else { return }
    if let player, playerItemID == item.id {
      let duration = player.duration > 0 ? player.duration : Double(item.duration ?? 0)
      bottomBar.videoControls.update(
        elapsed: player.currentTime,
        duration: duration,
        isPlaying: player.isPlaying,
        isMuted: player.isMuted
      )
      currentCell?.setVideoState(videoState(of: player))
      let isPlaying = player.isPlaying && !player.isBuffering
      if isPlaying != wasPlaying {
        wasPlaying = isPlaying
        if isPlaying { scheduleChromeAutoHide() } else { chromeHideWork?.cancel() }
      }
    } else {
      bottomBar.videoControls.update(
        elapsed: 0,
        duration: Double(item.duration ?? 0),
        isPlaying: false,
        isMuted: MediaGalleryVideoPlayer.prefersMuted
      )
    }
  }

  // MARK: - Dismiss drag

  @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
    guard let cell = currentCell else {
      // The page went away mid-drag; never leave paging disabled.
      if gesture.state != .began, gesture.state != .changed {
        pager.isScrollEnabled = true
        isDismissPanning = false
      }
      return
    }
    let translation = gesture.translation(in: view)
    let velocity = gesture.velocity(in: view)

    switch gesture.state {
      case .began:
        isDismissPanning = true
        pager.isScrollEnabled = false
        suppressCurrentSource()

      case .changed:
        let progress = min(1, abs(translation.y) / (view.bounds.height * 0.5))
        let scale = 1 - 0.18 * progress
        cell.scrollView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
          .scaledBy(x: scale, y: scale)
        backgroundView.alpha = 1 - 0.9 * progress
        let chromeAlpha = chromeVisible ? max(0, 1 - progress * 4) : 0
        topBar.alpha = chromeAlpha
        bottomBar.alpha = chromeAlpha

      case .ended, .cancelled, .failed:
        pager.isScrollEnabled = true
        // Where the drag would coast to: a flick back toward the middle cancels even after a
        // long drag, and a quick flick away dismisses from a short one.
        let projected = translation.y + velocity.y * 0.15
        let flicksAway = abs(velocity.y) > 800 && velocity.y.sign == translation.y.sign
        let shouldDismiss = gesture.state == .ended && (abs(projected) > 140 || flicksAway)
        if shouldDismiss {
          animateOut(velocity: velocity)
          return
        }
        // The drag can start while the pager is a few points off its page; settle it back.
        let pageOffset = CGPoint(x: CGFloat(currentIndex) * pageWidth, y: 0)
        if abs(pager.contentOffset.x - pageOffset.x) > 0.5 {
          pager.setContentOffset(pageOffset, animated: true)
        }
        UIView.animate(springDuration: 0.32, bounce: 0.12) {
          cell.scrollView.transform = .identity
          self.backgroundView.alpha = 1
          self.applyChromeAlpha()
        } completion: { _ in
          self.isDismissPanning = false
          if self.needsSourceApply { self.applySource() }
        }

      default:
        break
    }
  }
}

// MARK: - UICollectionView

extension MediaGalleryViewController: UICollectionViewDataSource, UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    items.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    // swiftlint:disable:next force_cast
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: MediaGalleryPageCell.reuseIdentifier,
      for: indexPath
    ) as! MediaGalleryPageCell
    let item = items[indexPath.item]
    cell.configure(
      item: item,
      placeholder: item.id == openingItemID ? openingImage : nil,
      pageGap: pageGap,
      displayScale: displayScale
    )
    cell.setWaitingForOriginal(item.id == waitingItemID)
    cell.onSingleTap = { [weak self] in
      guard let self else { return }
      setChromeVisible(!chromeVisible)
    }
    cell.onPlayTap = { [weak self] in
      guard let self, currentItem?.id == item.id else { return }
      toggleVideoPlayback()
    }
    cell.onZoomChange = { [weak self] zoomed in
      guard let self else { return }
      if zoomed {
        setChromeVisible(false)
      } else if needsSourceApply, !pager.isDragging, !pager.isDecelerating {
        applySource()
      }
    }
    cell.onLoadFailed = { [weak self] item in
      self?.source.refreshLinks(id: item.id) ?? false
    }
    cell.onVideoRetry = { [weak self] in
      guard let self, currentItem?.id == item.id else { return }
      stopVideo()
      startVideoIfNeeded(autoplay: true)
    }
    cell.onSkip = { [weak self] seconds in
      guard let self, currentItem?.id == item.id, let player = currentPlayer else { return false }
      let duration = player.duration > 0 ? player.duration : Double(item.duration ?? 0)
      guard duration >= Self.skippableDuration else { return false }
      player.skip(by: seconds)
      return true
    }
    cell.onHoldSpeedUp = { [weak self] holding in
      guard let self, currentItem?.id == item.id, let player = currentPlayer else { return false }
      if holding {
        guard player.isPlaying, rateBeforeHold == nil else { return false }
        rateBeforeHold = player.player.rate
        player.player.rate = 2
        chromeHideWork?.cancel()
        return true
      }
      guard let previous = rateBeforeHold else { return false }
      rateBeforeHold = nil
      if player.player.timeControlStatus != .paused { player.player.rate = previous }
      return true
    }
    if let player, playerItemID == item.id {
      cell.attach(player: player)
      cell.setVideoState(videoState(of: player))
    }
    return cell
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === pager, !isApplyingSource, pageWidth > 0, !items.isEmpty else { return }
    let index = min(max(0, Int((scrollView.contentOffset.x / pageWidth).rounded())), items.count - 1)
    guard index != currentIndex else { return }
    currentIndex = index
    currentIndexDidChange()
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    guard scrollView === pager else { return }
    pageDidSettle()
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    guard scrollView === pager, !decelerate else { return }
    pageDidSettle()
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    guard scrollView === pager else { return }
    pageDidSettle()
  }
}

// MARK: - Gestures

extension MediaGalleryViewController: UIGestureRecognizerDelegate {
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === dismissPan else { return true }
    guard !isDismissing, !isTransitioning, let cell = currentCell, !cell.isZoomed, !pager.isDecelerating else {
      return false
    }
    let velocity = dismissPan.velocity(in: view)
    return abs(velocity.y) > abs(velocity.x) * 1.2
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    gestureRecognizer === dismissPan && otherGestureRecognizer.view is UIScrollView
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard gestureRecognizer === dismissPan else { return true }
    var target = touch.view
    while let candidate = target, candidate !== view {
      if candidate is UIControl || candidate === topBar || candidate === bottomBar { return false }
      target = candidate.superview
    }
    return true
  }
}

/// Pages horizontally; while the gallery inserts or removes pages, keeps the current one in place.
private final class MediaGalleryPagerLayout: UICollectionViewFlowLayout {
  var pinnedIndex: Int?

  override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
    guard let pinnedIndex, let collectionView, collectionView.bounds.width > 0 else {
      return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
    }
    return CGPoint(x: CGFloat(pinnedIndex) * collectionView.bounds.width, y: proposedContentOffset.y)
  }
}

private enum MediaGalleryError: Error {
  case unavailable
}

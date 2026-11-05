import AVFoundation
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

  private weak var suppressedSourceView: UIView?
  private var suppressedSourceAlpha: CGFloat = 1

  private let pageGap: CGFloat = 20
  private let prefetcher = Nuke.ImagePrefetcher()

  // MARK: - Views

  private let backgroundView = UIView()
  private let pagerLayout = UICollectionViewFlowLayout()
  private lazy var pager = UICollectionView(frame: .zero, collectionViewLayout: pagerLayout)
  private let topBar = MediaGalleryTopBar()
  private let bottomBar = MediaGalleryBottomBar()
  private let toastView = UILabel()
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

    toastView.font = .systemFont(ofSize: 14, weight: .medium)
    toastView.textColor = .label
    toastView.textAlignment = .center
    toastView.backgroundColor = .secondarySystemBackground
    toastView.layer.cornerRadius = 18
    toastView.layer.masksToBounds = true
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
    pager.frame = frame
    pagerLayout.itemSize = frame.size
    pagerLayout.invalidateLayout()
    pager.layoutIfNeeded()
    isApplyingSource = true
    pager.contentOffset = CGPoint(x: CGFloat(currentIndex) * frame.width, y: 0)
    isApplyingSource = false
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
    let image = openingImage ?? currentCell?.imageView.image
    let sourceView = item.flatMap(sourceViewProvider)

    guard let image, let sourceView, sourceView.window != nil else {
      pager.isHidden = false
      pager.alpha = 0
      UIView.animate(withDuration: 0.2) {
        self.pager.alpha = 1
        self.backgroundView.alpha = 1
        self.applyChromeAlpha()
      } completion: { _ in
        self.didFinishAppearing()
      }
      return
    }

    let from = sourceView.convert(sourceView.bounds, to: view)
    let hero = makeHero(image: image, frame: from, cornerRadius: cornerRadius(for: sourceView))
    view.insertSubview(hero, belowSubview: topBar)
    suppress(sourceView)

    UIView.animate(springDuration: 0.42, bounce: 0) {
      hero.frame = self.fittedFrame(for: image.size)
      hero.layer.cornerRadius = 0
      self.backgroundView.alpha = 1
      self.applyChromeAlpha()
    } completion: { _ in
      self.pager.isHidden = false
      hero.removeFromSuperview()
      self.didFinishAppearing()
    }
  }

  private func didFinishAppearing() {
    isTransitioning = false
    startVideoIfNeeded(autoplay: true)
    prefetchNeighbors()
    if needsSourceApply { applySource() }
  }

  /// Flies the current item back to its thumbnail, or off screen when the thumbnail
  /// isn't visible.
  private func animateOut(velocity: CGPoint = .zero) {
    guard !isDismissing else { return }
    isDismissing = true
    isTransitioning = true
    stopVideo()

    let cell = currentCell
    let image = cell?.imageView.image
    let fromFrame = cell.map { $0.imageView.convert($0.imageView.bounds, to: view) }

    guard let image, let fromFrame, fromFrame.width > 0, fromFrame.height > 0 else {
      UIView.animate(withDuration: 0.2) {
        self.view.alpha = 0
      } completion: { _ in
        self.finishDismiss()
      }
      return
    }

    let hero = makeHero(image: image, frame: fromFrame, cornerRadius: 0)
    view.insertSubview(hero, belowSubview: topBar)
    pager.isHidden = true

    let target = currentItem.flatMap(sourceViewProvider).flatMap { $0.window == nil ? nil : $0 }
    if let target {
      let targetFrame = target.convert(target.bounds, to: view)
      if view.bounds.intersects(targetFrame), targetFrame.width > 1 {
        suppress(target)
        let radius = cornerRadius(for: target)
        let distance = max(1, hypot(targetFrame.midX - fromFrame.midX, targetFrame.midY - fromFrame.midY))
        let speed = hypot(velocity.x, velocity.y) / distance
        UIView.animate(springDuration: 0.38, bounce: 0, initialSpringVelocity: min(speed, 6)) {
          hero.frame = targetFrame
          hero.layer.cornerRadius = radius
          self.backgroundView.alpha = 0
          self.topBar.alpha = 0
          self.bottomBar.alpha = 0
        } completion: { _ in
          self.restoreSuppressedSource()
          hero.removeFromSuperview()
          self.finishDismiss()
        }
        return
      }
    }

    let reference = velocity.y != 0 ? velocity.y : fromFrame.midY - view.bounds.midY
    let direction: CGFloat = reference >= 0 ? 1 : -1
    UIView.animate(withDuration: 0.24, delay: 0, options: .curveEaseOut) {
      hero.frame = fromFrame.offsetBy(dx: velocity.x * 0.05, dy: direction * self.view.bounds.height)
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
      || isTransitioning || currentCell?.isZoomed == true
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
    items = next
    currentIndex = currentID.flatMap { id in next.firstIndex { $0.id == id } } ?? min(currentIndex, next.count - 1)

    isApplyingSource = true
    pager.reloadData()
    pager.layoutIfNeeded()
    pager.contentOffset = CGPoint(x: CGFloat(currentIndex) * pageWidth, y: 0)
    pager.layoutIfNeeded()
    isApplyingSource = false

    source.pageDidChange(to: currentIndex)
    if currentItem?.id != playerItemID {
      stopVideo()
    } else if let player, let item = currentItem, Self.playableURL(for: item) != player.url {
      // Fresh links arrived for the video on screen.
      let wasPlaying = player.isPlaying
      stopVideo()
      startVideoIfNeeded(autoplay: wasPlaying)
    } else if let player {
      currentCell?.attach(player: player)
    }
    updateChrome()
    prefetchNeighbors()
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
    updateChrome()
  }

  private func pageDidSettle() {
    for case let cell as MediaGalleryPageCell in pager.visibleCells where cell.item?.id != currentItem?.id {
      cell.resetZoom(animated: false)
    }
    startVideoIfNeeded(autoplay: true)
    prefetchNeighbors()
    if needsSourceApply { applySource() }
  }

  private func scrollToItem(at index: Int) {
    guard items.indices.contains(index), index != currentIndex else { return }
    pager.setContentOffset(CGPoint(x: CGFloat(index) * pageWidth, y: 0), animated: false)
    pageDidSettle()
  }

  private func prefetchNeighbors() {
    let range = max(0, currentIndex - 2) ... min(items.count - 1, currentIndex + 2)
    guard !items.isEmpty else { return }
    let urls = range.compactMap { index -> URL? in
      let item = items[index]
      return item.kind == .photo ? item.mediaURL : item.thumbnailURL
    }
    prefetcher.startPrefetching(with: urls)
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
  }

  private func updateChrome() {
    guard let item = currentItem else { return }
    let message = item.message
    topBar.update(title: Self.senderName(message), subtitle: message.map { Self.dateText($0.date) })
    topBar.menuButton.menu = makeMenu(for: item)
    topBar.menuButton.isHidden = topBar.menuButton.menu?.children.isEmpty ?? true

    let counter = items.count > 1 && source.isComplete ? "\(currentIndex + 1) of \(items.count)" : nil
    bottomBar.update(caption: message?.text, counter: counter, isVideo: item.kind == .video)
    bottomBar.strip.isHidden = items.count < 2
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

  private func makeMenu(for item: MediaGalleryItem) -> UIMenu {
    var children: [UIMenuElement] = []
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

    let controls = bottomBar.videoControls
    controls.playButton.addAction(UIAction { [weak self] _ in self?.toggleVideoPlayback() }, for: .touchUpInside)
    controls.onSeek = { [weak self] fraction in self?.player?.seek(to: fraction) }
    controls.onScrubChange = { [weak self] scrubbing in
      guard let self, let player else { return }
      if scrubbing {
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
      guard let image = await fullImage(for: item) else {
        showToast("Couldn't copy the photo", systemImage: "exclamationmark.triangle")
        return
      }
      UIPasteboard.general.image = image
      showToast("Copied", systemImage: "doc.on.doc")
    }
  }

  private func share(_ item: MediaGalleryItem) {
    Task {
      let activityItem: Any?
      switch item.kind {
        case .photo:
          activityItem = await fullImage(for: item)
        case .video:
          activityItem = try? await localVideoURL(for: item)
      }
      guard let activityItem else {
        showToast("Couldn't load this item", systemImage: "exclamationmark.triangle")
        return
      }
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
            guard let image = await fullImage(for: item) else { throw MediaGalleryError.unavailable }
            try await PHPhotoLibrary.shared().performChanges {
              PHAssetChangeRequest.creationRequestForAsset(from: image)
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

  private func fullImage(for item: MediaGalleryItem) async -> UIImage? {
    for url in [item.mediaURL, item.fallbackURL].compactMap({ $0 }) {
      if let image = try? await ImagePipeline.shared.image(for: url) {
        return image
      }
    }
    return nil
  }

  private func localVideoURL(for item: MediaGalleryItem) async throws -> URL {
    if let url = item.mediaURL, url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    guard let remote = [item.mediaURL, item.fallbackURL].compactMap({ $0 }).first(where: { !$0.isFileURL }) else {
      throw MediaGalleryError.unavailable
    }
    showToast("Downloading…", systemImage: "arrow.down.circle")
    let (downloaded, _) = try await URLSession.shared.download(from: remote)
    let ext = remote.pathExtension.isEmpty ? "mp4" : remote.pathExtension
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(ext)
    try FileManager.default.moveItem(at: downloaded, to: destination)
    return destination
  }

  private var toastHideWork: DispatchWorkItem?

  private func showToast(_ text: String, systemImage: String) {
    let attachment = NSTextAttachment(image: UIImage(systemName: systemImage)?
      .withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage())
    let string = NSMutableAttributedString(attachment: attachment)
    string.append(NSAttributedString(string: "  " + text))
    toastView.attributedText = string
    let size = toastView.sizeThatFits(CGSize(width: view.bounds.width - 64, height: 36))
    toastView.bounds = CGRect(x: 0, y: 0, width: size.width + 36, height: 36)
    toastView.center = CGPoint(x: view.bounds.midX, y: topBar.frame.maxY + 12)
    toastHideWork?.cancel()
    UIView.animate(withDuration: 0.2) { self.toastView.alpha = 1 }
    let work = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.25) { self?.toastView.alpha = 0 }
    }
    toastHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
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
    let player = MediaGalleryVideoPlayer(url: url)
    player.onUpdate = { [weak self] in self?.updateVideoControls() }
    self.player = player
    playerItemID = item.id
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

  private static func playableURL(for item: MediaGalleryItem) -> URL? {
    if let url = item.mediaURL, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    return item.fallbackURL
  }

  private func stopVideo() {
    guard let player else { return }
    player.stop()
    self.player = nil
    playerItemID = nil
    for case let cell as MediaGalleryPageCell in pager.visibleCells {
      cell.detachPlayer()
      cell.setPlaying(false)
    }
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
      bottomBar.videoControls.update(elapsed: player.currentTime, duration: duration, isPlaying: player.isPlaying)
      currentCell?.setPlaying(player.isPlaying)
    } else {
      bottomBar.videoControls.update(elapsed: 0, duration: Double(item.duration ?? 0), isPlaying: false)
    }
  }

  // MARK: - Dismiss drag

  @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
    guard let cell = currentCell else { return }
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
        let shouldDismiss = gesture.state == .ended && (abs(translation.y) > 110 || abs(velocity.y) > 900)
        if shouldDismiss {
          animateOut(velocity: velocity)
          return
        }
        UIView.animate(springDuration: 0.4, bounce: 0.2) {
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
    cell.configure(item: item, placeholder: item.id == openingItemID ? openingImage : nil, pageGap: pageGap)
    cell.onSingleTap = { [weak self] in
      guard let self else { return }
      setChromeVisible(!chromeVisible)
    }
    cell.onPlayTap = { [weak self] in
      guard let self, currentItem?.id == item.id else { return }
      toggleVideoPlayback()
    }
    cell.onZoomChange = { [weak self] zoomed in
      if zoomed { self?.setChromeVisible(false) }
    }
    cell.onLoadFailed = { [weak self] item in
      self?.source.refreshLinks(id: item.id) ?? false
    }
    if let player, playerItemID == item.id {
      cell.attach(player: player)
      cell.setPlaying(player.isPlaying)
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

private enum MediaGalleryError: Error {
  case unavailable
}

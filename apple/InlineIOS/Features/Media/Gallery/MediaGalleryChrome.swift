import Nuke
import UIKit

enum MediaGalleryChromeStyle {
  /// Interactive Liquid Glass on iOS 26, a gray capsule before it.
  static func glassConfiguration() -> UIButton.Configuration {
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = .glass()
    } else {
      configuration = .gray()
    }
    configuration.baseForegroundColor = .label
    configuration.cornerStyle = .capsule
    return configuration
  }

  static func iconButton(_ systemName: String, label: String, pointSize: CGFloat = 17) -> UIButton {
    var configuration = glassConfiguration()
    configuration.image = UIImage(
      systemName: systemName,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    )
    configuration.contentInsets = .zero
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = label
    button.isPointerInteractionEnabled = true
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 44),
      button.heightAnchor.constraint(equalToConstant: 44),
    ])
    return button
  }

  /// A non-interactive glass panel for text that sits over the photo.
  static func glassPanel(cornerRadius: CGFloat) -> UIVisualEffectView {
    let panel: UIVisualEffectView
    if #available(iOS 26.0, *) {
      panel = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    } else {
      panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    }
    panel.layer.cornerRadius = cornerRadius
    panel.layer.cornerCurve = .continuous
    panel.clipsToBounds = true
    panel.translatesAutoresizingMaskIntoConstraints = false
    return panel
  }
}

/// Bars let taps on their empty areas reach the photo, so a tap anywhere toggles the chrome.
class MediaGalleryPassthroughView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let hit = super.hitTest(point, with: event) else { return nil }
    var view: UIView? = hit
    while let current = view, current !== self {
      if current is UIControl || current is UIVisualEffectView || current is UICollectionView {
        return hit
      }
      view = current.superview
    }
    return nil
  }
}

// MARK: - Top bar

/// Close, sender and date, and the actions menu.
final class MediaGalleryTopBar: MediaGalleryPassthroughView {
  let closeButton = MediaGalleryChromeStyle.iconButton("chevron.backward", label: "Close")
  let menuButton = MediaGalleryChromeStyle.iconButton("ellipsis", label: "More")
  private let titlePanel = MediaGalleryChromeStyle.glassPanel(cornerRadius: 22)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.textColor = .label
    titleLabel.textAlignment = .center
    subtitleLabel.font = .systemFont(ofSize: 12)
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.textAlignment = .center

    let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    titles.axis = .vertical
    titles.alignment = .center
    titles.spacing = 0
    titles.translatesAutoresizingMaskIntoConstraints = false
    titlePanel.contentView.addSubview(titles)

    menuButton.showsMenuAsPrimaryAction = true
    addSubview(closeButton)
    addSubview(titlePanel)
    addSubview(menuButton)

    NSLayoutConstraint.activate([
      closeButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
      closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
      menuButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
      menuButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

      titlePanel.centerXAnchor.constraint(equalTo: centerXAnchor),
      titlePanel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      titlePanel.heightAnchor.constraint(equalToConstant: 44),
      titlePanel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 10),
      titlePanel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -10),

      titles.centerYAnchor.constraint(equalTo: titlePanel.contentView.centerYAnchor),
      titles.leadingAnchor.constraint(equalTo: titlePanel.contentView.leadingAnchor, constant: 18),
      titles.trailingAnchor.constraint(equalTo: titlePanel.contentView.trailingAnchor, constant: -18),

      bottomAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(title: String?, subtitle: String?) {
    titleLabel.text = title
    titleLabel.isHidden = title == nil
    subtitleLabel.text = subtitle
    subtitleLabel.isHidden = subtitle == nil
    titlePanel.isHidden = title == nil && subtitle == nil
  }
}

// MARK: - Bottom bar

/// Caption, thumbnail strip, video controls, and share with the position counter.
/// Everything else lives in the top menu.
final class MediaGalleryBottomBar: MediaGalleryPassthroughView {
  let strip = MediaGalleryThumbnailStrip()
  let videoControls = MediaGalleryVideoControls()
  let shareButton = MediaGalleryChromeStyle.iconButton("square.and.arrow.up", label: "Share")

  private let captionPanel = MediaGalleryChromeStyle.glassPanel(cornerRadius: 18)
  private let captionScroll = UIScrollView()
  private let captionLabel = UILabel()
  private let counterPanel = MediaGalleryChromeStyle.glassPanel(cornerRadius: 16)
  private let counterLabel = UILabel()
  private var captionHeight: NSLayoutConstraint!
  private var isCaptionExpanded = false

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    captionLabel.font = .systemFont(ofSize: 15)
    captionLabel.textColor = .label
    captionLabel.numberOfLines = 3
    captionLabel.translatesAutoresizingMaskIntoConstraints = false
    captionScroll.showsVerticalScrollIndicator = false
    captionScroll.translatesAutoresizingMaskIntoConstraints = false
    captionScroll.addSubview(captionLabel)
    captionPanel.contentView.addSubview(captionScroll)
    captionPanel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleCaption)))
    let captionRow = UIView()
    captionRow.translatesAutoresizingMaskIntoConstraints = false
    captionRow.addSubview(captionPanel)

    counterLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    counterLabel.textColor = .label
    counterLabel.textAlignment = .center
    counterLabel.translatesAutoresizingMaskIntoConstraints = false
    counterPanel.contentView.addSubview(counterLabel)

    let actions = UIView()
    actions.translatesAutoresizingMaskIntoConstraints = false
    actions.addSubview(shareButton)
    actions.addSubview(counterPanel)

    let stack = UIStackView(arrangedSubviews: [captionRow, strip, videoControls, actions])
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    captionHeight = captionScroll.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4),

      captionPanel.topAnchor.constraint(equalTo: captionRow.topAnchor),
      captionPanel.bottomAnchor.constraint(equalTo: captionRow.bottomAnchor),
      captionPanel.leadingAnchor.constraint(equalTo: captionRow.leadingAnchor, constant: 16),
      captionPanel.trailingAnchor.constraint(equalTo: captionRow.trailingAnchor, constant: -16),
      captionScroll.topAnchor.constraint(equalTo: captionPanel.contentView.topAnchor, constant: 10),
      captionScroll.bottomAnchor.constraint(equalTo: captionPanel.contentView.bottomAnchor, constant: -10),
      captionScroll.leadingAnchor.constraint(equalTo: captionPanel.contentView.leadingAnchor, constant: 14),
      captionScroll.trailingAnchor.constraint(equalTo: captionPanel.contentView.trailingAnchor, constant: -14),
      captionLabel.topAnchor.constraint(equalTo: captionScroll.contentLayoutGuide.topAnchor),
      captionLabel.bottomAnchor.constraint(equalTo: captionScroll.contentLayoutGuide.bottomAnchor),
      captionLabel.leadingAnchor.constraint(equalTo: captionScroll.frameLayoutGuide.leadingAnchor),
      captionLabel.trailingAnchor.constraint(equalTo: captionScroll.frameLayoutGuide.trailingAnchor),
      captionHeight,

      strip.heightAnchor.constraint(equalToConstant: MediaGalleryThumbnailStrip.height),
      videoControls.heightAnchor.constraint(equalToConstant: 48),

      actions.heightAnchor.constraint(equalToConstant: 44),
      shareButton.leadingAnchor.constraint(equalTo: actions.leadingAnchor, constant: 16),
      shareButton.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
      counterPanel.centerXAnchor.constraint(equalTo: actions.centerXAnchor),
      counterPanel.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
      counterPanel.heightAnchor.constraint(equalToConstant: 32),
      counterLabel.centerYAnchor.constraint(equalTo: counterPanel.contentView.centerYAnchor),
      counterLabel.leadingAnchor.constraint(equalTo: counterPanel.contentView.leadingAnchor, constant: 12),
      counterLabel.trailingAnchor.constraint(equalTo: counterPanel.contentView.trailingAnchor, constant: -12),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(caption: String?, counter: String?, isVideo: Bool) {
    let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
    captionLabel.text = caption
    captionPanel.superview?.isHidden = caption?.isEmpty ?? true
    isCaptionExpanded = false
    captionLabel.numberOfLines = 3
    counterLabel.text = counter
    counterPanel.isHidden = counter == nil
    videoControls.isHidden = !isVideo
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = max(0, captionScroll.bounds.width)
    let fitting = captionLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let limit = isCaptionExpanded ? (window?.bounds.height ?? 800) * 0.3 : fitting
    let height = min(fitting, limit)
    if captionHeight.constant != height {
      captionHeight.constant = height
    }
  }

  @objc private func toggleCaption() {
    isCaptionExpanded.toggle()
    captionLabel.numberOfLines = isCaptionExpanded ? 0 : 3
    captionScroll.setContentOffset(.zero, animated: false)
    UIView.animate(withDuration: 0.25) {
      self.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
  }
}

// MARK: - Video controls

/// Play or pause, elapsed time, a seek slider, and duration, on a glass capsule.
final class MediaGalleryVideoControls: UIView {
  let playButton = UIButton(type: .system)
  let slider = UISlider()
  private let panel = MediaGalleryChromeStyle.glassPanel(cornerRadius: 24)
  private let elapsedLabel = UILabel()
  private let durationLabel = UILabel()
  private(set) var isScrubbing = false

  var onSeek: ((Double) -> Void)?
  var onScrubChange: ((Bool) -> Void)?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    for label in [elapsedLabel, durationLabel] {
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
      label.textColor = .secondaryLabel
      label.text = "0:00"
      label.setContentHuggingPriority(.required, for: .horizontal)
    }
    playButton.tintColor = .label
    playButton.setContentHuggingPriority(.required, for: .horizontal)
    slider.minimumTrackTintColor = .label
    slider.maximumTrackTintColor = .tertiaryLabel
    slider.addTarget(self, action: #selector(sliderBegan), for: .touchDown)
    slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    slider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

    let stack = UIStackView(arrangedSubviews: [playButton, elapsedLabel, slider, durationLabel])
    stack.spacing = 10
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(panel)
    panel.contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      panel.topAnchor.constraint(equalTo: topAnchor),
      panel.bottomAnchor.constraint(equalTo: bottomAnchor),
      panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -16),
      stack.centerYAnchor.constraint(equalTo: panel.contentView.centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: 28),
    ])
    update(elapsed: 0, duration: 0, isPlaying: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(elapsed: Double, duration: Double, isPlaying: Bool) {
    elapsedLabel.text = Self.format(elapsed)
    durationLabel.text = Self.format(duration)
    if !isScrubbing {
      slider.value = duration > 0 ? Float(elapsed / duration) : 0
    }
    playButton.setImage(
      UIImage(
        systemName: isPlaying ? "pause.fill" : "play.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
      ),
      for: .normal
    )
    playButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
  }

  static func format(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%d:%02d", minutes, secs)
  }

  @objc private func sliderBegan() {
    isScrubbing = true
    onScrubChange?(true)
  }

  @objc private func sliderChanged() {
    onSeek?(Double(slider.value))
  }

  @objc private func sliderEnded() {
    isScrubbing = false
    onSeek?(Double(slider.value))
    onScrubChange?(false)
  }
}

// MARK: - Thumbnail strip

/// A scrubbable row of thumbnails with the current item widened to its aspect ratio.
final class MediaGalleryThumbnailStrip: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  static let height: CGFloat = 42
  private static let baseWidth: CGFloat = 28
  private static let spacing: CGFloat = 2
  private static let currentMargin: CGFloat = 6

  private let layout = UICollectionViewFlowLayout()
  private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
  private var items: [MediaGalleryItem] = []
  private var currentIndex = 0
  /// While the user drags the strip, no item is widened so the row stays still under the finger.
  private var isScrubbing = false
  private var lastScrubbedIndex: Int?

  /// The user tapped or dragged to an item.
  var onSelect: ((Int) -> Void)?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = Self.spacing
    layout.minimumInteritemSpacing = Self.spacing
    collectionView.backgroundColor = .clear
    collectionView.showsHorizontalScrollIndicator = false
    collectionView.decelerationRate = .fast
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(Cell.self, forCellWithReuseIdentifier: Cell.reuseIdentifier)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset = max(0, bounds.width / 2 - Self.baseWidth / 2)
    if layout.sectionInset.left != inset {
      layout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
      layout.invalidateLayout()
      collectionView.layoutIfNeeded()
      scrollToCurrent(animated: false)
    }
  }

  func update(items: [MediaGalleryItem], currentIndex: Int, animated: Bool) {
    let itemsChanged = items.map(\.id) != self.items.map(\.id)
    self.items = items
    guard !isScrubbing || itemsChanged else { return }
    let indexChanged = currentIndex != self.currentIndex
    self.currentIndex = currentIndex
    if itemsChanged {
      isScrubbing = false
      collectionView.reloadData()
      collectionView.layoutIfNeeded()
      scrollToCurrent(animated: false)
    } else if indexChanged {
      let changes = {
        self.layout.invalidateLayout()
        self.collectionView.layoutIfNeeded()
        self.scrollToCurrent(animated: false)
      }
      animated ? UIView.animate(withDuration: 0.25, animations: changes) : changes()
    }
  }

  private func scrollToCurrent(animated: Bool) {
    guard items.indices.contains(currentIndex),
          let attributes = layout.layoutAttributesForItem(at: IndexPath(item: currentIndex, section: 0))
    else { return }
    let x = attributes.center.x - collectionView.bounds.width / 2
    let maxX = max(0, collectionView.contentSize.width - collectionView.bounds.width)
    collectionView.setContentOffset(CGPoint(x: min(max(0, x), maxX), y: 0), animated: animated)
  }

  private func indexNearestCenter() -> Int? {
    let center = CGPoint(x: collectionView.contentOffset.x + collectionView.bounds.width / 2, y: Self.height / 2)
    if let indexPath = collectionView.indexPathForItem(at: center) {
      return indexPath.item
    }
    return collectionView.indexPathsForVisibleItems.min {
      guard let a = collectionView.layoutAttributesForItem(at: $0),
            let b = collectionView.layoutAttributesForItem(at: $1) else { return false }
      return abs(a.center.x - center.x) < abs(b.center.x - center.x)
    }?.item
  }

  // MARK: Data source

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    items.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    // swiftlint:disable:next force_cast
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Cell.reuseIdentifier, for: indexPath) as! Cell
    cell.configure(items[indexPath.item])
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    guard !isScrubbing, indexPath.item == currentIndex else {
      return CGSize(width: Self.baseWidth, height: Self.height)
    }
    let size = items[indexPath.item].pixelSize ?? CGSize(width: 1, height: 1)
    let width = min(max(Self.height * size.width / max(size.height, 1), Self.baseWidth), Self.height * 1.8)
    return CGSize(width: width + Self.currentMargin * 2, height: Self.height)
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    onSelect?(indexPath.item)
  }

  // MARK: Scrubbing

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    isScrubbing = true
    lastScrubbedIndex = currentIndex
    UIView.animate(withDuration: 0.2) {
      self.layout.invalidateLayout()
      self.collectionView.layoutIfNeeded()
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard isScrubbing, let index = indexNearestCenter(), index != lastScrubbedIndex else { return }
    lastScrubbedIndex = index
    UISelectionFeedbackGenerator().selectionChanged()
    onSelect?(index)
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { endScrubbing() }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    endScrubbing()
  }

  private func endScrubbing() {
    guard isScrubbing else { return }
    isScrubbing = false
    if let index = lastScrubbedIndex { currentIndex = index }
    UIView.animate(withDuration: 0.25) {
      self.layout.invalidateLayout()
      self.collectionView.layoutIfNeeded()
      self.scrollToCurrent(animated: false)
    }
  }

  // MARK: Cell

  private final class Cell: UICollectionViewCell {
    static let reuseIdentifier = "MediaGalleryThumbnailCell"
    private let imageView = UIImageView()
    private var task: ImageTask?
    private var itemID: Int64?

    override init(frame: CGRect) {
      super.init(frame: frame)
      imageView.contentMode = .scaleAspectFill
      imageView.clipsToBounds = true
      imageView.backgroundColor = .tertiarySystemFill
      imageView.layer.cornerRadius = 3
      contentView.addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      // The current item's margin is part of its cell, so the image stays inset.
      let inset = bounds.width > MediaGalleryThumbnailStrip.baseWidth + 1 ? MediaGalleryThumbnailStrip.currentMargin : 0
      imageView.frame = bounds.insetBy(dx: inset, dy: 0)
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      task?.cancel()
      task = nil
      itemID = nil
      imageView.image = nil
    }

    func configure(_ item: MediaGalleryItem) {
      guard itemID != item.id else { return }
      task?.cancel()
      itemID = item.id
      imageView.image = item.strippedImage
      guard let url = item.thumbnailURL ?? item.mediaURL else { return }
      let request = ImageRequest(
        url: url,
        processors: [ImageProcessors.Resize(size: CGSize(width: 80, height: 80), contentMode: .aspectFill)]
      )
      if let cached = ImagePipeline.shared.cache.cachedImage(for: request) {
        imageView.image = cached.image
        return
      }
      let id = item.id
      task = ImagePipeline.shared.loadImage(with: request) { [weak self] result in
        guard let self, self.itemID == id, case let .success(response) = result else { return }
        self.imageView.image = response.image
      }
    }
  }
}

import AppKit
import InlineKit

final class ComposeAttachments: NSView {
  private weak var compose: ComposeAppKit?

  private var attachments: [String: ImageAttachmentView] = [:]
  private var videoAttachments: [String: VideoAttachmentView] = [:]
  private var docAttachments: [String: DocumentView] = [:]
  private var orderedMediaIds: [String] = []
  private var mediaMeta: [String: MediaMeta] = [:]

  private enum MediaSection {
    case media
  }

  private var mediaDataSource: NSCollectionViewDiffableDataSource<MediaSection, String>!
  // AppKit diffable insert animations can be inconsistent in some drag/drop paths
  // (especially when the NSTextView text system owns the operation).
  // Keep a small explicit fade-in for newly inserted items.
  // TODO(@mo): Investigate AppKit animation suppression during text-system drag ops.
  private var pendingInsertionIds: Set<String> = []
  private var lastMediaIds: Set<String> = []

  private var horizontalContentInset: CGFloat = 0 {
    didSet {
      updateHorizontalInsets()
    }
  }

  private let mediaScrollView: NSScrollView
  private let mediaCollectionView: NSCollectionView
  private let mediaLayout: NSCollectionViewFlowLayout
  private let filesStackView: NSStackView

  private let maxAttachmentWidth: CGFloat = 180
  private let minAttachmentWidth: CGFloat = 60

  private var heightConstraint: NSLayoutConstraint!
  private var mediaScrollHeightConstraint: NSLayoutConstraint!
  private var mediaCollectionHeightConstraint: NSLayoutConstraint!
  private var mediaTopConstraint: NSLayoutConstraint!
  private var mediaBottomConstraint: NSLayoutConstraint!
  private var filesLeadingConstraint: NSLayoutConstraint!
  private var verticalPadding: CGFloat = Theme.composeAttachmentsVPadding

  init(frame: NSRect, compose: ComposeAppKit) {
    self.compose = compose

    mediaLayout = NSCollectionViewFlowLayout()
    mediaLayout.scrollDirection = .horizontal
    mediaLayout.minimumInteritemSpacing = 8
    mediaLayout.minimumLineSpacing = 8

    mediaCollectionView = NSCollectionView(frame: .zero)
    mediaCollectionView.collectionViewLayout = mediaLayout
    mediaCollectionView.isSelectable = false
    mediaCollectionView.backgroundColors = [.clear]
    mediaCollectionView.translatesAutoresizingMaskIntoConstraints = false

    mediaScrollView = NSScrollView(frame: .zero)
    mediaScrollView.drawsBackground = false
    mediaScrollView.hasHorizontalScroller = true
    mediaScrollView.hasVerticalScroller = false
    mediaScrollView.translatesAutoresizingMaskIntoConstraints = false
    mediaScrollView.scrollerStyle = .overlay
    mediaScrollView.documentView = mediaCollectionView

    filesStackView = NSStackView(frame: .zero)
    filesStackView.orientation = .vertical
    filesStackView.alignment = .leading
    filesStackView.spacing = 0
    filesStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    filesStackView.translatesAutoresizingMaskIntoConstraints = false

    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Layout / Height

  func getHeight() -> CGFloat {
    if attachments.isEmpty, docAttachments.isEmpty, videoAttachments.isEmpty {
      return 0
    }

    let hasMedia = !(attachments.isEmpty && videoAttachments.isEmpty)
    let hasDocuments = !docAttachments.isEmpty
    let paddings = (hasMedia || hasDocuments) ? 2 * verticalPadding : 0
    let mediaHeight = hasMedia ? Theme.composeAttachmentImageHeight : 0
    let documentsHeight = hasDocuments ? Theme.documentViewHeight * CGFloat(docAttachments.count) : 0
    return paddings + mediaHeight + documentsHeight
  }

  public func updateHeight(animated: Bool = false) {
    let newHeight = getHeight()
    let mediaHeight = (attachments.isEmpty && videoAttachments.isEmpty)
      ? 0
      : (Theme.composeAttachmentImageHeight + 2 * verticalPadding)
    let collectionHeight = (attachments.isEmpty && videoAttachments.isEmpty)
      ? 0
      : Theme.composeAttachmentImageHeight
    let padding = collectionHeight == 0 ? 0 : verticalPadding

    let applyChanges = {
      self.heightConstraint.constant = newHeight
      self.mediaScrollHeightConstraint.constant = mediaHeight
      self.mediaCollectionHeightConstraint.constant = collectionHeight
      self.mediaTopConstraint.constant = padding
      self.mediaBottomConstraint.constant = -padding
      self.mediaScrollView.isHidden = mediaHeight == 0
      if mediaHeight == 0 {
        self.resetMediaScrollPosition()
      }
    }

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.allowsImplicitAnimation = true
        applyChanges()
        self.layoutSubtreeIfNeeded()
      }
    } else {
      applyChanges()
    }
  }

  private func setupView() {
    clipsToBounds = true

    heightConstraint = heightAnchor.constraint(equalToConstant: getHeight())
    mediaScrollHeightConstraint = mediaScrollView.heightAnchor.constraint(equalToConstant: 0)

    mediaCollectionView.delegate = self
    mediaCollectionView.register(
      AttachmentCollectionItem.self,
      forItemWithIdentifier: AttachmentCollectionItem.identifier
    )
    mediaDataSource = makeMediaDataSource()

    // Pin collection view to the scroll view's content view
    let clipView = mediaScrollView.contentView
    mediaTopConstraint = mediaCollectionView.topAnchor.constraint(
      equalTo: clipView.topAnchor,
      constant: verticalPadding
    )
    mediaBottomConstraint = mediaCollectionView.bottomAnchor.constraint(
      equalTo: clipView.bottomAnchor,
      constant: -verticalPadding
    )
    mediaCollectionHeightConstraint = mediaCollectionView.heightAnchor.constraint(
      equalToConstant: Theme.composeAttachmentImageHeight
    )

    NSLayoutConstraint.activate([
      mediaCollectionView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
      mediaTopConstraint,
      mediaBottomConstraint,
      mediaCollectionView.widthAnchor.constraint(greaterThanOrEqualTo: clipView.widthAnchor),
      mediaCollectionHeightConstraint,
    ])

    addSubview(mediaScrollView)
    addSubview(filesStackView)

    filesLeadingConstraint = filesStackView.leadingAnchor.constraint(
      equalTo: leadingAnchor,
      constant: horizontalContentInset
    )

    NSLayoutConstraint.activate([
      heightConstraint,
      mediaScrollHeightConstraint,

      mediaScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      mediaScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      mediaScrollView.topAnchor.constraint(equalTo: topAnchor),

      filesLeadingConstraint,
      filesStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      filesStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
      filesStackView.topAnchor.constraint(equalTo: mediaScrollView.bottomAnchor),
    ])

    applyMediaSnapshot(animating: false)
    updateHeight(animated: false)
  }

  // MARK: - Media

  public func removeImageView(id: String) {
    attachments.removeValue(forKey: id)
    orderedMediaIds.removeAll { $0 == id }
    mediaMeta.removeValue(forKey: id)
    pendingInsertionIds.remove(id)
    applyMediaSnapshot(animating: true)
    updateHeight(animated: true)
  }

  public func addImageView(_ image: NSImage, id: String) {
    if attachments[id] != nil { return }
    let aspectRatio = image.size.width / max(image.size.height, 1)
    mediaMeta[id] = .init(kind: .image, aspectRatio: aspectRatio)
    orderedMediaIds.append(id)
    let attachmentView = ImageAttachmentView(
      image: image,
      onRemove: { [weak self] in
        self?.compose?.removeImage(id)
      },
      height: Theme.composeAttachmentImageHeight,
      maxWidth: maxAttachmentWidth,
      minWidth: minAttachmentWidth
    )
    attachmentView.translatesAutoresizingMaskIntoConstraints = false

    attachments[id] = attachmentView
    applyMediaSnapshot(animating: true)
    updateHeight(animated: true)
  }

  public func addVideoView(_ videoInfo: VideoInfo, id: String) {
    let thumbnail: NSImage? = {
      guard let localPath = videoInfo.thumbnail?.sizes.first?.localPath else { return nil }
      let url = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(localPath)
      return NSImage(contentsOf: url)
    }()

    let videoURL: URL? = {
      guard let localPath = videoInfo.video.localPath else { return nil }
      return FileHelpers.getLocalCacheDirectory(for: .videos).appendingPathComponent(localPath)
    }()

    addVideoView(thumbnail: thumbnail, videoURL: videoURL, id: id)
  }

  public func addVideoView(thumbnail: NSImage?, videoURL: URL?, id: String) {
    if videoAttachments[id] != nil { return }

    let aspectRatio: CGFloat
    if let thumb = thumbnail {
      aspectRatio = thumb.size.width / max(thumb.size.height, 1)
    } else {
      aspectRatio = 16.0 / 9.0
    }
    mediaMeta[id] = .init(kind: .video, aspectRatio: aspectRatio)
    orderedMediaIds.append(id)

    let view = VideoAttachmentView(
      thumbnail: thumbnail,
      videoURL: videoURL,
      onRemove: { [weak self] in
        self?.compose?.removeVideo(id)
      },
      height: Theme.composeAttachmentImageHeight,
      maxWidth: maxAttachmentWidth,
      minWidth: minAttachmentWidth
    )

    view.translatesAutoresizingMaskIntoConstraints = false

    videoAttachments[id] = view
    applyMediaSnapshot(animating: true)
    updateHeight(animated: true)
  }

  public func removeVideoView(id: String) {
    videoAttachments.removeValue(forKey: id)
    orderedMediaIds.removeAll { $0 == id }
    mediaMeta.removeValue(forKey: id)
    pendingInsertionIds.remove(id)
    applyMediaSnapshot(animating: true)
    updateHeight(animated: true)
  }

  // MARK: - Documents

  public func addDocumentView(_ documentInfo: DocumentInfo, id: String) {
    // Check if we already have this document
    if let existingView = docAttachments[id] {
      existingView.update(with: documentInfo)
      return
    }

    // Create a new document view
    let documentView = DocumentView(
      documentInfo: documentInfo,
      removeAction: { [weak self] in
        self?.compose?.removeFile(id)
      }
    )

    documentView.translatesAutoresizingMaskIntoConstraints = false
    docAttachments[id] = documentView

    filesStackView.addArrangedSubview(documentView)

    // Animate the appearance
    documentView.fadeIn()

    // Update height
    updateHeight(animated: true)
  }

  public func removeDocumentView(id: String) {
    guard let documentView = docAttachments[id] else { return }
    docAttachments.removeValue(forKey: id)

    if docAttachments.isEmpty {
      // Animate removal of last document
      documentView.fadeOut { [weak self] in
        self?.filesStackView.removeArrangedSubview(documentView)
        documentView.removeFromSuperview()
        self?.updateHeight(animated: true)
      }
    } else {
      filesStackView.removeArrangedSubview(documentView)
      documentView.removeFromSuperview()
      updateHeight(animated: true)
    }
  }

  // Add this method to clear all document views
  public func clearDocumentViews(animated: Bool = false) {
    for (_, documentView) in docAttachments {
      filesStackView.removeArrangedSubview(documentView)
      documentView.removeFromSuperview()
    }

    docAttachments.removeAll()
  }

  // MARK: - Clear

  public func clearViews(animated: Bool = false) {
    attachments.removeAll()

    videoAttachments.removeAll()
    orderedMediaIds.removeAll()
    mediaMeta.removeAll()
    pendingInsertionIds.removeAll()
    lastMediaIds.removeAll()

    // Clear documents
    clearDocumentViews(animated: animated)

    applyMediaSnapshot(animating: animated)
    updateHeight(animated: animated)
  }

  // MARK: - Helpers

  private func makeMediaDataSource() -> NSCollectionViewDiffableDataSource<MediaSection, String> {
    NSCollectionViewDiffableDataSource<MediaSection, String>(
      collectionView: mediaCollectionView
    ) { [weak self] collectionView, indexPath, id in
      guard let self else { return nil }
      let item = collectionView.makeItem(
        withIdentifier: AttachmentCollectionItem.identifier,
        for: indexPath
      )

      guard let attachmentItem = item as? AttachmentCollectionItem else { return item }

      if let attachmentView = self.view(for: id) {
        attachmentItem.configure(with: attachmentView)
      } else {
        attachmentItem.configureEmpty()
      }

      if self.pendingInsertionIds.contains(id) {
        attachmentItem.animateInsertion()
        self.pendingInsertionIds.remove(id)
      }

      return attachmentItem
    }
  }

  private func applyMediaSnapshot(animating: Bool) {
    let newIds = Set(orderedMediaIds)
    let inserted = newIds.subtracting(lastMediaIds)
    if !inserted.isEmpty {
      pendingInsertionIds.formUnion(inserted)
    }
    lastMediaIds = newIds

    var snapshot = NSDiffableDataSourceSnapshot<MediaSection, String>()
    snapshot.appendSections([.media])
    snapshot.appendItems(orderedMediaIds, toSection: .media)
    mediaDataSource.apply(snapshot, animatingDifferences: animating)
  }

  private func clampedWidth(for aspectRatio: CGFloat) -> CGFloat {
    let calculated = Theme.composeAttachmentImageHeight * aspectRatio
    return min(max(calculated, minAttachmentWidth), maxAttachmentWidth)
  }

  private func updateHorizontalInsets() {
    mediaLayout.sectionInset = NSEdgeInsets(
      top: 0,
      left: horizontalContentInset,
      bottom: 0,
      right: horizontalContentInset
    )
    filesLeadingConstraint?.constant = horizontalContentInset
    mediaLayout.invalidateLayout()
  }

  func setHorizontalContentInset(_ inset: CGFloat) {
    horizontalContentInset = inset
  }

  private func view(for id: String) -> NSView? {
    if let imageView = attachments[id] {
      return imageView
    }
    if let videoView = videoAttachments[id] {
      return videoView
    }
    return nil
  }

  private func resetMediaScrollPosition() {
    let clipView = mediaScrollView.contentView
    clipView.setBoundsOrigin(.zero)
    mediaScrollView.reflectScrolledClipView(clipView)
  }
}

// MARK: - Collection View

extension ComposeAttachments: NSCollectionViewDelegateFlowLayout {
  func collectionView(
    _ collectionView: NSCollectionView,
    layout collectionViewLayout: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    guard let id = mediaDataSource.itemIdentifier(for: indexPath) else {
      return NSSize(width: minAttachmentWidth, height: Theme.composeAttachmentImageHeight)
    }
    let aspect = mediaMeta[id]?.aspectRatio ?? 1.0
    let width = clampedWidth(for: aspect)
    return NSSize(width: width, height: Theme.composeAttachmentImageHeight)
  }
}

// MARK: - Helpers

private struct MediaMeta {
  enum Kind {
    case image
    case video
  }

  let kind: Kind
  let aspectRatio: CGFloat
}

private final class AttachmentCollectionItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("AttachmentCollectionItem")

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    configureEmpty()
    view.alphaValue = 1
  }

  func configure(with child: NSView) {
    configureEmpty()

    child.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(child)

    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      child.topAnchor.constraint(equalTo: view.topAnchor),
      child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  func configureEmpty() {
    view.subviews.forEach { $0.removeFromSuperview() }
  }

  func animateInsertion() {
    view.wantsLayer = true
    view.alphaValue = 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      context.allowsImplicitAnimation = true
      view.animator().alphaValue = 1
    }
  }
}

// MARK: - Animations

extension NSView {
  func fadeOut(completionHandler: (() -> Void)?) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      animator().alphaValue = 0
    } completionHandler: {
      completionHandler?()
    }
  }

  func fadeIn() {
    wantsLayer = true
    layer?.opacity = 0
    DispatchQueue.main.async { [weak self] in
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.allowsImplicitAnimation = true
        self?.layer?.opacity = 1
      }
    }
  }
}

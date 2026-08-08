import AppKit
import InlineKit

final class ComposeAttachments: NSView {
  private weak var compose: (any ComposeAttachmentOwner)?

  private var attachments: [String: ImageAttachmentView] = [:]
  private var videoAttachments: [String: VideoAttachmentView] = [:]
  private var documentModels: [String: DocumentAttachmentModel] = [:]
  private var orderedDocumentIds: [String] = []
  private var orderedMediaIds: [String] = []
  private var mediaMeta: [String: MediaMeta] = [:]

  private enum MediaSection {
    case media
  }

  private enum DocumentSection {
    case documents
  }

  private var mediaDataSource: NSCollectionViewDiffableDataSource<MediaSection, String>!
  private var documentDataSource: NSCollectionViewDiffableDataSource<DocumentSection, String>!
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
  private let documentScrollView: NSScrollView
  private let documentCollectionView: NSCollectionView
  private let documentLayout: NSCollectionViewFlowLayout

  private let maxAttachmentWidth: CGFloat = 180
  private let minAttachmentWidth: CGFloat = 60
  private let maxDocumentViewportHeight = DocumentPresentationPlan.thumbnailSize * 4
    + Theme.composeAttachmentsVPadding * 2

  private var heightConstraint: NSLayoutConstraint!
  private var mediaScrollHeightConstraint: NSLayoutConstraint!
  private var mediaCollectionHeightConstraint: NSLayoutConstraint!
  private var documentScrollHeightConstraint: NSLayoutConstraint!
  private var documentCollectionHeightConstraint: NSLayoutConstraint!
  private var mediaTopConstraint: NSLayoutConstraint!
  private var mediaBottomConstraint: NSLayoutConstraint!
  private var documentsLeadingConstraint: NSLayoutConstraint!
  private var verticalPadding: CGFloat = Theme.composeAttachmentsVPadding

  init(frame: NSRect, compose: any ComposeAttachmentOwner) {
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

    documentLayout = NSCollectionViewFlowLayout()
    documentLayout.scrollDirection = .vertical
    documentLayout.minimumInteritemSpacing = 0
    documentLayout.minimumLineSpacing = 0

    documentCollectionView = NSCollectionView(frame: .zero)
    documentCollectionView.collectionViewLayout = documentLayout
    documentCollectionView.isSelectable = false
    documentCollectionView.backgroundColors = [.clear]
    documentCollectionView.translatesAutoresizingMaskIntoConstraints = false

    documentScrollView = NSScrollView(frame: .zero)
    documentScrollView.drawsBackground = false
    documentScrollView.hasHorizontalScroller = false
    documentScrollView.hasVerticalScroller = true
    documentScrollView.autohidesScrollers = true
    documentScrollView.scrollerStyle = .overlay
    documentScrollView.translatesAutoresizingMaskIntoConstraints = false
    documentScrollView.documentView = documentCollectionView

    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Layout / Height

  func getHeight() -> CGFloat {
    if attachments.isEmpty, documentModels.isEmpty, videoAttachments.isEmpty {
      return 0
    }

    let hasMedia = !(attachments.isEmpty && videoAttachments.isEmpty)
    let mediaHeight = hasMedia ? Theme.composeAttachmentImageHeight + 2 * verticalPadding : 0
    return mediaHeight + documentViewportHeight(hasMedia: hasMedia)
  }

  private func documentContentHeight(hasMedia: Bool) -> CGFloat {
    guard !documentModels.isEmpty else { return 0 }
    let rowsHeight = orderedDocumentIds.reduce(CGFloat.zero) { height, id in
      height + (documentModels[id]?.preferredHeight ?? 0)
    }
    return rowsHeight + (hasMedia ? 0 : 2 * verticalPadding)
  }

  private func documentViewportHeight(hasMedia: Bool) -> CGFloat {
    min(documentContentHeight(hasMedia: hasMedia), maxDocumentViewportHeight)
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
    let documentContentHeight = documentContentHeight(hasMedia: collectionHeight > 0)
    let documentViewportHeight = min(documentContentHeight, maxDocumentViewportHeight)

    let applyChanges = {
      self.heightConstraint.constant = newHeight
      self.mediaScrollHeightConstraint.constant = mediaHeight
      self.mediaCollectionHeightConstraint.constant = collectionHeight
      self.documentScrollHeightConstraint.constant = documentViewportHeight
      self.documentCollectionHeightConstraint.constant = documentContentHeight
      self.mediaTopConstraint.constant = padding
      self.mediaBottomConstraint.constant = -padding
      self.mediaScrollView.isHidden = mediaHeight == 0
      self.documentScrollView.isHidden = self.documentModels.isEmpty
      self.documentLayout.sectionInset = (mediaHeight == 0 && !self.documentModels.isEmpty)
        ? NSEdgeInsets(top: self.verticalPadding, left: 0, bottom: self.verticalPadding, right: 0)
        : .zero
      self.documentLayout.invalidateLayout()
      if mediaHeight == 0 {
        self.resetMediaScrollPosition()
      }
      if documentContentHeight <= documentViewportHeight {
        self.resetDocumentScrollPosition()
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
    documentScrollHeightConstraint = documentScrollView.heightAnchor.constraint(equalToConstant: 0)

    mediaCollectionView.delegate = self
    mediaCollectionView.register(
      AttachmentCollectionItem.self,
      forItemWithIdentifier: AttachmentCollectionItem.identifier
    )
    mediaDataSource = makeMediaDataSource()

    documentCollectionView.delegate = self
    documentCollectionView.register(
      DocumentAttachmentCollectionItem.self,
      forItemWithIdentifier: DocumentAttachmentCollectionItem.identifier
    )
    documentDataSource = makeDocumentDataSource()

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

    let documentClipView = documentScrollView.contentView
    documentCollectionHeightConstraint = documentCollectionView.heightAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      mediaCollectionView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
      mediaTopConstraint,
      mediaBottomConstraint,
      mediaCollectionView.widthAnchor.constraint(greaterThanOrEqualTo: clipView.widthAnchor),
      mediaCollectionHeightConstraint,
    ])

    addSubview(mediaScrollView)
    addSubview(documentScrollView)

    documentsLeadingConstraint = documentCollectionView.leadingAnchor.constraint(
      equalTo: documentClipView.leadingAnchor,
      constant: horizontalContentInset
    )

    NSLayoutConstraint.activate([
      heightConstraint,
      mediaScrollHeightConstraint,
      documentScrollHeightConstraint,
      documentCollectionHeightConstraint,

      mediaScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      mediaScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      mediaScrollView.topAnchor.constraint(equalTo: topAnchor),

      documentsLeadingConstraint,
      documentCollectionView.trailingAnchor.constraint(equalTo: documentClipView.trailingAnchor),
      documentCollectionView.topAnchor.constraint(equalTo: documentClipView.topAnchor),

      documentScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      documentScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      documentScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      documentScrollView.topAnchor.constraint(equalTo: mediaScrollView.bottomAnchor),
    ])

    applyMediaSnapshot(animating: false)
    applyDocumentSnapshot(animating: false)
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

  public func addPendingDocument(url: URL, id: String) {
    let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    documentModels[id] = .pending(
      PendingDocumentPresentation(
        fileName: url.lastPathComponent,
        fileSize: fileSize,
        reservesThumbnailSpace: DocumentThumbnailIntegration.canAttemptGeneration(at: url)
      )
    )
    if !orderedDocumentIds.contains(id) {
      orderedDocumentIds.append(id)
    }
    applyDocumentSnapshot(animating: true, reloading: id)
    updateHeight(animated: true)
  }

  public func addDocumentView(_ documentInfo: DocumentInfo, id: String) {
    documentModels[id] = .ready(documentInfo)
    if !orderedDocumentIds.contains(id) {
      orderedDocumentIds.append(id)
    }
    applyDocumentSnapshot(animating: true, reloading: id)
    updateHeight(animated: true)
  }

  public func removeDocumentView(id: String) {
    guard documentModels.removeValue(forKey: id) != nil else { return }
    orderedDocumentIds.removeAll { $0 == id }
    applyDocumentSnapshot(animating: true)
    updateHeight(animated: true)
  }

  public func clearDocumentViews(animated: Bool = false) {
    documentModels.removeAll()
    orderedDocumentIds.removeAll()
    applyDocumentSnapshot(animating: animated)
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

  private func makeDocumentDataSource() -> NSCollectionViewDiffableDataSource<DocumentSection, String> {
    NSCollectionViewDiffableDataSource<DocumentSection, String>(
      collectionView: documentCollectionView
    ) { [weak self] collectionView, indexPath, id in
      guard let self, let model = documentModels[id] else { return nil }
      let item = collectionView.makeItem(
        withIdentifier: DocumentAttachmentCollectionItem.identifier,
        for: indexPath
      )
      guard let documentItem = item as? DocumentAttachmentCollectionItem else { return item }
      documentItem.configure(with: model) { [weak self] in
        self?.compose?.removeFile(id)
      }
      return documentItem
    }
  }

  private func applyDocumentSnapshot(animating: Bool, reloading id: String? = nil) {
    var snapshot = NSDiffableDataSourceSnapshot<DocumentSection, String>()
    snapshot.appendSections([.documents])
    snapshot.appendItems(orderedDocumentIds, toSection: .documents)
    if let id, documentDataSource.snapshot().indexOfItem(id) != nil {
      snapshot.reloadItems([id])
    }
    documentDataSource.apply(snapshot, animatingDifferences: animating)
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
    documentsLeadingConstraint.constant = horizontalContentInset
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

  private func resetDocumentScrollPosition() {
    let clipView = documentScrollView.contentView
    clipView.setBoundsOrigin(.zero)
    documentScrollView.reflectScrolledClipView(clipView)
  }
}

// MARK: - Collection View

extension ComposeAttachments: NSCollectionViewDelegateFlowLayout {
  func collectionView(
    _ collectionView: NSCollectionView,
    layout collectionViewLayout: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    if collectionView === documentCollectionView {
      guard let id = documentDataSource.itemIdentifier(for: indexPath),
            let model = documentModels[id]
      else {
        return NSSize(width: max(0, collectionView.bounds.width), height: Theme.documentViewHeight)
      }
      return NSSize(width: max(0, collectionView.bounds.width), height: model.preferredHeight)
    }

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

private enum DocumentAttachmentModel {
  case pending(PendingDocumentPresentation)
  case ready(DocumentInfo)

  var preferredHeight: CGFloat {
    switch self {
    case let .pending(presentation):
      presentation.preferredHeight
    case let .ready(documentInfo):
      DocumentPresentationPlan.preferredHeight(for: documentInfo)
    }
  }
}

private struct PendingDocumentPresentation {
  let fileName: String
  let fileSize: Int?
  let reservesThumbnailSpace: Bool

  var preferredHeight: CGFloat {
    reservesThumbnailSpace ? DocumentPresentationPlan.thumbnailSize : Theme.documentViewHeight
  }

  var mediaSize: CGFloat {
    reservesThumbnailSpace ? DocumentPresentationPlan.thumbnailSize : DocumentPresentationPlan.iconSize
  }
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

private final class DocumentAttachmentCollectionItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("DocumentAttachmentCollectionItem")

  override func loadView() {
    view = AttachmentHostView()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    (view as? AttachmentHostView)?.host(nil)
  }

  func configure(with model: DocumentAttachmentModel, onRemove: @escaping () -> Void) {
    let child: NSView = switch model {
    case let .pending(presentation):
      PendingDocumentAttachmentView(presentation: presentation, onRemove: onRemove)
    case let .ready(documentInfo):
      DocumentView(documentInfo: documentInfo, removeAction: onRemove)
    }
    (view as? AttachmentHostView)?.host(child)
  }
}

private final class AttachmentHostView: NSView {
  private weak var hostedView: NSView?

  func host(_ child: NSView?) {
    hostedView?.removeFromSuperview()
    hostedView = child
    guard let child else { return }
    addSubview(child)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    hostedView?.frame = bounds
  }
}

private final class PendingDocumentAttachmentView: NSView {
  private let presentation: PendingDocumentPresentation
  private let onRemove: () -> Void
  private let progressIndicator = NSProgressIndicator()
  private let progressContainer = NSView()
  private let fileNameLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let closeButton = NSButton()

  init(presentation: PendingDocumentPresentation, onRemove: @escaping () -> Void) {
    self.presentation = presentation
    self.onRemove = onRemove
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: presentation.preferredHeight))
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    progressContainer.wantsLayer = true
    progressContainer.layer?.cornerRadius = presentation.reservesThumbnailSpace
      ? DocumentPresentationPlan.thumbnailCornerRadius
      : DocumentPresentationPlan.iconSize / 2
    progressContainer.layer?.cornerCurve = .continuous
    progressContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor

    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.startAnimation(nil)

    fileNameLabel.stringValue = presentation.fileName
    fileNameLabel.font = .systemFont(ofSize: 12)
    fileNameLabel.lineBreakMode = .byTruncatingMiddle
    fileNameLabel.cell?.truncatesLastVisibleLine = true

    let size = presentation.fileSize.map { FileHelpers.formatFileSize(UInt64(max(0, $0))) }
    statusLabel.stringValue = ["Preparing", size].compactMap { $0 }.joined(separator: "  ·  ")
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabelColor

    closeButton.bezelStyle = .circular
    closeButton.isBordered = false
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")
    closeButton.target = self
    closeButton.action = #selector(remove)

    progressContainer.addSubview(progressIndicator)
    addSubview(progressContainer)
    addSubview(fileNameLabel)
    addSubview(statusLabel)
    addSubview(closeButton)
  }

  override func layout() {
    super.layout()
    let spinnerSize: CGFloat = 16
    let closeSize = DocumentPresentationPlan.closeButtonSize
    let mediaSize = presentation.mediaSize
    let mediaFrame = NSRect(
      x: 0,
      y: floor((bounds.height - mediaSize) / 2),
      width: mediaSize,
      height: mediaSize
    )
    let textX = mediaFrame.maxX + DocumentPresentationPlan.iconSpacing
    let textWidth = max(0, bounds.width - textX - 32)
    let centerY = floor(bounds.midY)

    progressContainer.frame = mediaFrame
    progressIndicator.frame = NSRect(
      x: floor((mediaSize - spinnerSize) / 2),
      y: floor((mediaSize - spinnerSize) / 2),
      width: spinnerSize,
      height: spinnerSize
    )
    fileNameLabel.frame = NSRect(x: textX, y: centerY + 1, width: textWidth, height: 16)
    statusLabel.frame = NSRect(x: textX, y: centerY - 17, width: textWidth, height: 16)
    closeButton.frame = NSRect(
      x: max(0, bounds.width - closeSize),
      y: floor(centerY - closeSize / 2),
      width: closeSize,
      height: closeSize
    )
  }

  @objc private func remove() {
    onRemove()
  }
}

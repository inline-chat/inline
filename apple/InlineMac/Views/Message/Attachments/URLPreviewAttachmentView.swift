import AppKit
import InlineKit
import InlineUI
import Logger
import Quartz

final class URLPreviewAttachmentView: NSView, AttachmentView {
  private typealias Layout = URLPreviewAttachmentLayout
  private typealias Mode = URLPreviewAttachmentLayout.Mode

  private struct PhotoRefreshKey: Equatable {
    var photo: PhotoInfo
    var width: Int
    var height: Int
  }

  private struct ViewFrameConstraints {
    let x: NSLayoutConstraint
    let y: NSLayoutConstraint
    let width: NSLayoutConstraint
    let height: NSLayoutConstraint

    func update(to rect: NSRect) {
      update(x, rect.origin.x)
      update(y, rect.origin.y)
      update(width, rect.width)
      update(height, rect.height)
    }

    private func update(_ constraint: NSLayoutConstraint, _ value: CGFloat) {
      guard constraint.constant != value else { return }
      constraint.constant = value
    }
  }

  private(set) var fullAttachment: FullAttachment
  private var message: Message
  private let usesOutgoingBubbleStyle: Bool
  private let mode: Mode
  private let largeStyle: UrlPreviewLargeStyle

  var attachment: Attachment {
    fullAttachment.attachment
  }

  func canUpdate(with fullAttachment: FullAttachment) -> Bool {
    fullAttachment.urlPreview != nil &&
      Self.mode(for: fullAttachment) == mode &&
      Self.largeStyle(for: fullAttachment) == largeStyle
  }

  func update(fullAttachment next: FullAttachment, message: Message) {
    guard canUpdate(with: next) else { return }

    let previousPhotoId = fullAttachment.photoInfo?.id
    let previousAuthorPhotoId = fullAttachment.authorPhotoInfo?.id
    fullAttachment = next
    self.message = message
    layoutPlan = nil
    if previousPhotoId != next.photoInfo?.id {
      clearPreviewImageURL()
      previewPhotoRefreshKey = nil
    }
    if previousAuthorPhotoId != next.authorPhotoInfo?.id {
      authorPhotoRefreshKey = nil
    }

    configure()
    updateColors()
    needsLayout = true
  }

  private var previewURL: URL?
  private var previewImageURL: URL?
  private var tempPreviewImageURL: URL?
  private var pressed = false
  private var layoutPlan: Layout.Plan?
  private var viewFrameConstraints: [ObjectIdentifier: ViewFrameConstraints] = [:]
  private var previewPhotoRefreshKey: PhotoRefreshKey?
  private var authorPhotoRefreshKey: PhotoRefreshKey?

  override var isFlipped: Bool {
    true
  }

  private lazy var accentView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    return view
  }()

  private lazy var backgroundView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = mode == .large ? Layout.largeCornerRadius : Layout.cornerRadius
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var imageContainer: PreviewImageContainerView = {
    let view = PreviewImageContainerView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = mode == .large ? 0 : Layout.imageCornerRadius
    view.layer?.masksToBounds = true
    view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    view.setContentCompressionResistancePriority(.required, for: .horizontal)
    return view
  }()

  private lazy var photoView: PlatformPhotoView = {
    let view = PlatformPhotoView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.photoContentMode = .aspectFill
    view.showsTinyThumbnailBackground = true
    view.showsLoadingPlaceholder = true
    view.layer?.cornerRadius = mode == .large ? 0 : Layout.imageCornerRadius
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var authorAvatarView: PlatformPhotoView = {
    let view = PlatformPhotoView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.photoContentMode = .aspectFill
    view.showsTinyThumbnailBackground = true
    view.showsLoadingPlaceholder = true
    view.layer?.cornerRadius = Layout.authorAvatarSize / 2
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var authorLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = Layout.authorFont
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var authorSubtitleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = Layout.authorSubtitleFont
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var playIconView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.symbolConfiguration = .init(pointSize: Layout.playIconSize, weight: .medium)
    view.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
    view.imageScaling = .scaleProportionallyUpOrDown
    return view
  }()

  private lazy var playOverlayView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
    view.layer?.cornerRadius = Layout.playOverlaySize / 2
    view.layer?.masksToBounds = true
    view.isHidden = true
    return view
  }()

  private lazy var providerPlaceholderView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.imageScaling = .scaleProportionallyUpOrDown
    view.isHidden = true
    return view
  }()

  private lazy var titleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = Layout.titleFont
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var descriptionLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = mode == .large ? Layout.largeDescriptionFont : Layout.compactDescriptionFont
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  init(fullAttachment: FullAttachment, message: Message, usesOutgoingBubbleStyle: Bool) {
    self.fullAttachment = fullAttachment
    self.message = message
    self.usesOutgoingBubbleStyle = usesOutgoingBubbleStyle
    self.mode = Self.mode(for: fullAttachment)
    self.largeStyle = Self.largeStyle(for: fullAttachment)
    super.init(frame: .zero)

    guard fullAttachment.urlPreview != nil else { return }
    setup()
    configure()
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func mode(for fullAttachment: FullAttachment) -> Mode {
    Layout.mode(for: fullAttachment)
  }

  private static func largeStyle(for fullAttachment: FullAttachment) -> UrlPreviewLargeStyle {
    fullAttachment.urlPreview?.largePreviewStyle ?? .standard
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = mode == .large ? Layout.largeCornerRadius : Layout.cornerRadius
    layer?.masksToBounds = true
    translatesAutoresizingMaskIntoConstraints = false
    PressScaleAnimator.prepare(self)
    accentView.isHidden = mode == .large

    addSubview(backgroundView)
    addSubview(accentView)
    addSubview(imageContainer)
    addSubview(titleLabel)
    addSubview(descriptionLabel)
    addSubview(authorAvatarView)
    addSubview(authorLabel)
    addSubview(authorSubtitleLabel)

    imageContainer.addSubview(photoView)
    imageContainer.addSubview(providerPlaceholderView)
    imageContainer.addSubview(playOverlayView)
    playOverlayView.addSubview(playIconView)
    imageContainer.contextMenuProvider = { [weak self] in
      self?.makeContextMenu()
    }
  }

  private func configure() {
    guard let preview = fullAttachment.urlPreview else { return }

    let isVideo = preview.isVideoPreview
    let display = Layout.displayContent(for: preview, mode: mode)
    let largeDisplay = mode == .large ? preview.largeDisplayContent(maxDescriptionLength: Layout.largeDescriptionMaxLength) : nil
    let titleText: String? = if let largeDisplay {
      largeDisplay.title
    } else {
      display.title
    }
    let descriptionText: String? = if let largeDisplay {
      largeDisplay.style == .x ? largeDisplay.body : largeDisplay.subtitle
    } else {
      display.subtitle
    }
    previewURL = preview.openURL
    toolTip = preview.title ?? preview.url

    let usesMultilineTitle = mode == .large && largeStyle != .x
    titleLabel.stringValue = titleText ?? ""
    titleLabel.lineBreakMode = usesMultilineTitle ? .byWordWrapping : .byTruncatingTail
    titleLabel.maximumNumberOfLines = usesMultilineTitle ? Layout.largeTitleMaxLines : 1
    titleLabel.isHidden = titleLabel.stringValue.isEmpty
    descriptionLabel.lineBreakMode = mode == .large ? .byWordWrapping : .byTruncatingTail
    descriptionLabel.maximumNumberOfLines = mode == .large ? 0 : 1
    descriptionLabel.stringValue = descriptionText ?? ""
    descriptionLabel.isHidden = descriptionLabel.stringValue.isEmpty
    configureAuthorRow(preview: preview, display: largeDisplay)

    setAccessibilityLabel(
      [descriptionText, largeDisplay?.authorName ?? preview.largePreviewAuthorName, largeDisplay?.authorSubtitle, titleText]
        .compactMap(\.self)
        .joined(separator: ": ")
    )
    setAccessibilityRole(.group)

    playOverlayView.isHidden = !isVideo
    playIconView.isHidden = !isVideo
    let hasPhoto = fullAttachment.photoInfo != nil
    let showsProviderPlaceholder = !isVideo && fullAttachment.photoInfo == nil && preview.isNotionPreview
    configureImage(
      showLoadingPlaceholder: isVideo && hasPhoto,
      showIconPlaceholder: isVideo && !hasPhoto,
      opensLinkOnImage: isVideo,
      providerPlaceholderImage: showsProviderPlaceholder ? NSImage(named: "notion-logo") : nil
    )
  }

  private func configureAuthorRow(preview: UrlPreview, display: UrlPreviewLargeDisplayContent?) {
    guard mode == .large else {
      authorAvatarView.isHidden = true
      authorLabel.isHidden = true
      authorSubtitleLabel.isHidden = true
      authorAvatarView.setPhoto(nil)
      authorPhotoRefreshKey = nil
      return
    }

    guard preview.shouldShowLargePreviewAuthor(hasAuthorPhoto: fullAttachment.authorPhotoInfo != nil) else {
      authorAvatarView.isHidden = true
      authorLabel.isHidden = true
      authorSubtitleLabel.isHidden = true
      authorAvatarView.setPhoto(nil)
      authorPhotoRefreshKey = nil
      return
    }

    if let authorPhotoInfo = fullAttachment.authorPhotoInfo {
      authorAvatarView.isHidden = false
      authorAvatarView.setPhoto(authorPhotoInfo, reloadMessageOnFinish: message)
    } else {
      authorAvatarView.isHidden = true
      authorAvatarView.setPhoto(nil)
      authorPhotoRefreshKey = nil
    }

    authorLabel.stringValue = display?.authorName ?? ""
    authorLabel.isHidden = authorLabel.stringValue.isEmpty
    authorSubtitleLabel.stringValue = display?.authorSubtitle ?? ""
    authorSubtitleLabel.isHidden = authorSubtitleLabel.stringValue.isEmpty
  }

  func apply(layout: URLPreviewAttachmentLayout.Plan) {
    apply(plan: layout)
    needsLayout = true
  }

  override func layout() {
    let width = bounds.width > 0 ? bounds.width : (layoutPlan?.size.width ?? 0)
    guard width > 0 else {
      clearLayoutConstraints()
      super.layout()
      return
    }

    let plan: Layout.Plan
    if let layoutPlan, layoutPlan.mode == mode, abs(layoutPlan.size.width - width) < 0.5 {
      plan = layoutPlan
    } else {
      plan = Layout.plan(for: fullAttachment, width: width)
    }

    apply(plan: plan)
    super.layout()
    imageContainer.layoutSubtreeIfNeeded()
    photoView.layoutSubtreeIfNeeded()
    authorAvatarView.layoutSubtreeIfNeeded()

    refreshPreviewPhotoIfNeeded()
    refreshAuthorPhotoIfNeeded()
  }

  private func apply(plan: Layout.Plan) {
    layoutPlan = plan
    switch mode {
    case .compact:
      guard let compact = plan.compact else { return }
      apply(compact: compact)
    case .large:
      guard let large = plan.large else { return }
      apply(large: large)
    }
  }

  private func apply(compact plan: Layout.CompactPlan) {
    setConstrainedFrame(plan.backgroundFrame, for: backgroundView)
    setConstrainedFrame(plan.accentFrame, for: accentView)
    accentView.isHidden = false
    setConstrainedFrame(plan.titleFrame, for: titleLabel)
    setConstrainedFrame(plan.descriptionFrame, for: descriptionLabel)
    setConstrainedFrame(nil, for: authorAvatarView)
    setConstrainedFrame(nil, for: authorLabel)
    setConstrainedFrame(nil, for: authorSubtitleLabel)
    applyImageLayout(
      containerFrame: plan.imageFrame,
      providerPlaceholderFrame: plan.providerPlaceholderFrame,
      playOverlayFrame: plan.playOverlayFrame,
      playIconFrame: plan.playIconFrame
    )
  }

  private func apply(large plan: Layout.LargePlan) {
    setConstrainedFrame(plan.backgroundFrame, for: backgroundView)
    setConstrainedFrame(nil, for: accentView)
    accentView.isHidden = true
    setConstrainedFrame(plan.titleFrame, for: titleLabel)
    setConstrainedFrame(plan.descriptionFrame, for: descriptionLabel)
    setConstrainedFrame(plan.authorAvatarFrame, for: authorAvatarView)
    setConstrainedFrame(plan.authorNameFrame, for: authorLabel)
    setConstrainedFrame(plan.authorSubtitleFrame, for: authorSubtitleLabel)
    applyImageLayout(
      containerFrame: plan.mediaFrame,
      providerPlaceholderFrame: plan.providerPlaceholderFrame,
      playOverlayFrame: plan.playOverlayFrame,
      playIconFrame: plan.playIconFrame
    )
  }

  private func applyImageLayout(
    containerFrame: Layout.Frame?,
    providerPlaceholderFrame: Layout.Frame?,
    playOverlayFrame: Layout.Frame?,
    playIconFrame: Layout.Frame?
  ) {
    setConstrainedFrame(containerFrame, for: imageContainer)
    let photoFrame = containerFrame.map {
      NSRect(x: 0, y: 0, width: $0.width, height: $0.height)
    } ?? .zero
    setConstrainedFrame(photoFrame, for: photoView)
    setConstrainedFrame(localRect(providerPlaceholderFrame, in: containerFrame), for: providerPlaceholderView)
    setConstrainedFrame(localRect(playOverlayFrame, in: containerFrame), for: playOverlayView)
    setConstrainedFrame(localRect(playIconFrame, in: playOverlayFrame), for: playIconView)
  }

  private func clearLayoutConstraints() {
    let views: [NSView] = [
      backgroundView,
      accentView,
      imageContainer,
      titleLabel,
      descriptionLabel,
      authorAvatarView,
      authorLabel,
      authorSubtitleLabel,
      photoView,
      providerPlaceholderView,
      playOverlayView,
      playIconView,
    ]
    views.forEach { setConstrainedFrame(nil, for: $0) }
  }

  private func setConstrainedFrame(_ frame: Layout.Frame?, for view: NSView) {
    setConstrainedFrame(frame?.rect ?? .zero, for: view)
  }

  private func setConstrainedFrame(_ frame: NSRect, for view: NSView) {
    frameConstraints(for: view).update(to: frame)
  }

  private func frameConstraints(for view: NSView) -> ViewFrameConstraints {
    let id = ObjectIdentifier(view)
    if let constraints = viewFrameConstraints[id] {
      return constraints
    }

    guard let superview = view.superview else {
      preconditionFailure("Expected \(type(of: view)) to have a superview before applying URL preview layout")
    }

    let constraints = ViewFrameConstraints(
      x: view.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
      y: view.topAnchor.constraint(equalTo: superview.topAnchor),
      width: view.widthAnchor.constraint(equalToConstant: 0),
      height: view.heightAnchor.constraint(equalToConstant: 0)
    )
    NSLayoutConstraint.activate([
      constraints.x,
      constraints.y,
      constraints.width,
      constraints.height,
    ])
    viewFrameConstraints[id] = constraints
    return constraints
  }

  private func refreshPreviewPhotoIfNeeded() {
    guard let photoInfo = fullAttachment.photoInfo else {
      return
    }

    guard !imageContainer.isHidden, !photoView.isHidden else {
      return
    }

    guard photoView.bounds.width > 0, photoView.bounds.height > 0 else {
      return
    }

    let key = PhotoRefreshKey(
      photo: photoInfo,
      width: Int(photoView.bounds.width),
      height: Int(photoView.bounds.height)
    )
    guard previewPhotoRefreshKey != key else {
      return
    }
    previewPhotoRefreshKey = key
    photoView.setPhoto(photoInfo, reloadMessageOnFinish: message)
  }

  private func refreshAuthorPhotoIfNeeded() {
    guard let photoInfo = fullAttachment.authorPhotoInfo else {
      return
    }

    guard !authorAvatarView.isHidden else {
      return
    }

    guard authorAvatarView.bounds.width > 0, authorAvatarView.bounds.height > 0 else {
      return
    }

    let key = PhotoRefreshKey(
      photo: photoInfo,
      width: Int(authorAvatarView.bounds.width),
      height: Int(authorAvatarView.bounds.height)
    )
    guard authorPhotoRefreshKey != key else {
      return
    }
    authorPhotoRefreshKey = key
    authorAvatarView.setPhoto(photoInfo, reloadMessageOnFinish: message)
  }

  private func localRect(_ frame: Layout.Frame?, in parent: Layout.Frame?) -> NSRect {
    guard let frame, let parent else { return .zero }
    return NSRect(
      x: frame.x - parent.x,
      y: frame.y - parent.y,
      width: frame.width,
      height: frame.height
    )
  }

  private func configureImage(
    showLoadingPlaceholder: Bool,
    showIconPlaceholder: Bool,
    opensLinkOnImage: Bool,
    providerPlaceholderImage: NSImage?
  ) {
    imageContainer.onTap = nil
    providerPlaceholderView.image = providerPlaceholderImage
    providerPlaceholderView.isHidden = providerPlaceholderImage == nil
    imageContainer.layer?.backgroundColor = providerPlaceholderImage == nil
      ? imagePlaceholderBackgroundColor.cgColor
      : NSColor.clear.cgColor

    guard let photoInfo = fullAttachment.photoInfo else {
      clearPreviewImageURL()
      imageContainer.isHidden = !showLoadingPlaceholder && !showIconPlaceholder && providerPlaceholderImage == nil
      photoView.isHidden = providerPlaceholderImage != nil || showIconPlaceholder
      photoView.showsLoadingPlaceholder = showLoadingPlaceholder && providerPlaceholderImage == nil
      photoView.setPhoto(nil)
      previewPhotoRefreshKey = nil
      return
    }

    imageContainer.isHidden = false
    photoView.isHidden = false
    providerPlaceholderView.isHidden = true
    imageContainer.layer?.backgroundColor = imagePlaceholderBackgroundColor.cgColor
    photoView.showsLoadingPlaceholder = true
    photoView.setPhoto(photoInfo, reloadMessageOnFinish: message)

    if !opensLinkOnImage {
      imageContainer.onTap = { [weak self] in
        self?.openPhotoPreview(for: photoInfo)
      }
    }
  }

  private func openPreviewURL() {
    guard let previewURL else {
      MessageGestureTrace.debug("URLPreviewAttachmentView.openPreviewURL result=noURL")
      return
    }
    MessageGestureTrace.debug("URLPreviewAttachmentView.openPreviewURL url=\(MessageGestureTrace.url(previewURL))")
    NSWorkspace.shared.open(previewURL)
  }

  @objc private func openPreviewURLFromMenu() {
    openPreviewURL()
  }

  @objc private func copyPreviewURL() {
    guard let previewURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(previewURL.absoluteString, forType: .string)
  }

  @objc private func removePreviewFromMenu() {
    removeURLPreviewAttachment()
  }

  @objc private func neverShowPreviewFromMenu() {
    guard let context = previewExclusionContext() else { return }

    Task {
      do {
        _ = try await Api.realtime.send(.addSpaceUrlPreviewExclusion(
          spaceId: context.spaceId,
          host: context.pattern.host,
          pathPrefix: nil,
          peerId: message.peerId,
          messageId: message.messageId
        ))
      } catch {
        Log.shared.error("Failed to exclude URL preview host", error: error)
        DispatchQueue.main.async { [weak self] in
          self?.showExcludeErrorAlert(error: error)
        }
      }
    }
  }

  @objc private func openPhotoPreviewFromMenu() {
    guard let photoInfo = fullAttachment.photoInfo else { return }
    openPhotoPreview(for: photoInfo)
  }

  private func openPhotoPreview(for photoInfo: PhotoInfo) {
    guard let panel = QLPreviewPanel.shared() else { return }
    let localURL = localPhotoURL(for: photoInfo)
    let controlsPanel = controlsPreviewPanel(panel)

    if localURL == nil,
       let tempPreviewImageURL,
       panel.isVisible,
       controlsPanel,
       previewImageURL == tempPreviewImageURL
    {
      panel.orderOut(nil)
      return
    }

    guard let imageURL = localURL ?? temporaryPhotoURL() else {
      if panel.isVisible, controlsPanel {
        panel.orderOut(nil)
        return
      }
      openPreviewURL()
      return
    }

    if panel.isVisible, controlsPanel, previewImageURL == imageURL {
      panel.orderOut(nil)
      return
    }

    previewImageURL = imageURL
    window?.makeFirstResponder(self)
    panel.updateController()
    panel.makeKeyAndOrderFront(nil)
  }

  private func controlsPreviewPanel(_ panel: QLPreviewPanel) -> Bool {
    (panel.dataSource as AnyObject?) === self
  }

  private var accentColor: NSColor {
    usesOutgoingBubbleStyle ? .white.withAlphaComponent(0.8) : .controlAccentColor
  }

  private var backgroundColor: NSColor {
    usesOutgoingBubbleStyle ? .white.withAlphaComponent(0.08) : .labelColor.withAlphaComponent(0.02)
  }

  private var imagePlaceholderBackgroundColor: NSColor {
    .labelColor.withAlphaComponent(0.05)
  }

  private var canRemovePreview: Bool {
    message.out == true && fullAttachment.attachment.attachmentId != nil
  }

  private var primaryTextColor: NSColor {
    usesOutgoingBubbleStyle ? .white : .labelColor
  }

  private var secondaryTextColor: NSColor {
    usesOutgoingBubbleStyle ? .white.withAlphaComponent(0.72) : .secondaryLabelColor
  }

  private var tertiaryTextColor: NSColor {
    usesOutgoingBubbleStyle ? .white.withAlphaComponent(0.55) : .tertiaryLabelColor
  }

  private func updateColors() {
    layer?.backgroundColor = backgroundColor.cgColor
    backgroundView.layer?.backgroundColor = backgroundColor.cgColor
    accentView.layer?.backgroundColor = accentColor.cgColor
    titleLabel.textColor = primaryTextColor
    descriptionLabel.textColor = mode == .large && largeStyle == .x ? primaryTextColor : secondaryTextColor
    if mode == .large {
      authorLabel.textColor = primaryTextColor
      authorSubtitleLabel.textColor = tertiaryTextColor
    }
    playOverlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
    playIconView.contentTintColor = .white
  }

  private func localPhotoURL(for photoInfo: PhotoInfo) -> URL? {
    for localPath in localPhotoPaths(for: photoInfo) {
      let url = FileCache.getUrl(for: .photos, localPath: localPath)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }

    return nil
  }

  private func localPhotoPaths(for photoInfo: PhotoInfo) -> [String] {
    var paths: [String] = []
    if let localPath = photoInfo.bestPhotoSize()?.localPath, !localPath.isEmpty {
      paths.append(localPath)
    }

    let fallbackPaths = photoInfo.sizes
      .filter { $0.type != "s" && $0.localPath?.isEmpty == false }
      .sorted { lhs, rhs in
        let lhsArea = max((lhs.width ?? 0) * (lhs.height ?? 0), 0)
        let rhsArea = max((rhs.width ?? 0) * (rhs.height ?? 0), 0)
        if lhsArea != rhsArea {
          return lhsArea > rhsArea
        }

        return (lhs.size ?? 0) > (rhs.size ?? 0)
      }
      .compactMap(\.localPath)

    for localPath in fallbackPaths where !paths.contains(localPath) {
      paths.append(localPath)
    }

    return paths
  }

  private func hasPhotoPreview(for photoInfo: PhotoInfo) -> Bool {
    localPhotoURL(for: photoInfo) != nil || photoView.displayedImage != nil
  }

  private func temporaryPhotoURL() -> URL? {
    if let tempPreviewImageURL {
      try? FileManager.default.removeItem(at: tempPreviewImageURL)
      self.tempPreviewImageURL = nil
    }

    guard let image = photoView.displayedImage,
          let data = image.tiffRepresentation
    else {
      return nil
    }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-url-preview-\(UUID().uuidString)")
      .appendingPathExtension("tiff")
    do {
      try data.write(to: url)
      tempPreviewImageURL = url
      return url
    } catch {
      return nil
    }
  }

  private func clearPreviewImageURL() {
    if let panel = QLPreviewPanel.shared(),
       panel.isVisible,
       controlsPreviewPanel(panel)
    {
      panel.orderOut(nil)
    }

    previewImageURL = nil
    if let tempPreviewImageURL {
      try? FileManager.default.removeItem(at: tempPreviewImageURL)
      self.tempPreviewImageURL = nil
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateColors()
    if window != nil {
      PressScaleAnimator.prepare(self)
      PressScaleAnimator.prepare(imageContainer)
    } else {
      setPressed(false)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  override func rightMouseDown(with event: NSEvent) {
    if showContextMenu(with: event) {
      return
    }

    super.rightMouseDown(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    MessageGestureTrace.debug(
      "URLPreviewAttachmentView.mouseDown type=\(event.type.rawValue) clicks=\(event.clickCount) point=\(MessageGestureTrace.point(convert(event.locationInWindow, from: nil))) modifiers=\(event.modifierFlags.rawValue)"
    )
    if event.modifierFlags.contains(.control), showContextMenu(with: event) {
      MessageGestureTrace.debug("URLPreviewAttachmentView.mouseDown action=contextMenu")
      return
    }

    guard event.type == .leftMouseDown, event.clickCount == 1, previewURL != nil else {
      MessageGestureTrace.trace("URLPreviewAttachmentView.mouseDown forwardingToSuper")
      super.mouseDown(with: event)
      return
    }

    setPressed(true)
    guard let window else {
      setPressed(false)
      return
    }

    while let next = window.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp],
      until: .distantFuture,
      inMode: .eventTracking,
      dequeue: true
    ) {
      let location = convert(next.locationInWindow, from: nil)
      let isInside = bounds.contains(location)
      switch next.type {
      case .leftMouseDragged:
        setPressed(isInside)
      case .leftMouseUp:
        setPressed(false)
        if isInside {
          MessageGestureTrace.debug("URLPreviewAttachmentView.mouseUp action=openPreviewURL")
          openPreviewURL()
        }
        return
      default:
        break
      }
    }

    setPressed(false)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, bounds.contains(point) else {
      MessageGestureTrace.trace(
        "URLPreviewAttachmentView.hitTest point=\(MessageGestureTrace.point(point)) result=nil hidden=\(isHidden)"
      )
      return nil
    }

    let imagePoint = imageContainer.convert(point, from: self)
    if !imageContainer.isHidden,
       imageContainer.hasTapAction,
       imageContainer.bounds.contains(imagePoint),
       let hit = imageContainer.hitTest(imagePoint)
    {
      MessageGestureTrace.trace(
        "URLPreviewAttachmentView.hitTest point=\(MessageGestureTrace.point(point)) result=image hit=\(type(of: hit))"
      )
      return hit
    }

    MessageGestureTrace.trace("URLPreviewAttachmentView.hitTest point=\(MessageGestureTrace.point(point)) result=self")
    return self
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    makeContextMenu() ?? super.menu(for: event)
  }

  private func showContextMenu(with event: NSEvent) -> Bool {
    guard let menu = makeContextMenu() else { return false }
    setPressed(false)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
    return true
  }

  private func setPressed(_ pressed: Bool) {
    guard self.pressed != pressed else { return }
    self.pressed = pressed
    alphaValue = pressed ? 0.92 : 1
    PressScaleAnimator.setPressed(pressed, on: self)
  }

  private func makeContextMenu() -> NSMenu? {
    guard previewURL != nil else { return nil }

    let menu = NSMenu()

    let openAction = NSMenuItem(title: "Open Link", action: #selector(openPreviewURLFromMenu), keyEquivalent: "")
    openAction.target = self
    openAction.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
    menu.addItem(openAction)

    let copyAction = NSMenuItem(title: "Copy Link", action: #selector(copyPreviewURL), keyEquivalent: "")
    copyAction.target = self
    copyAction.image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: nil)
    menu.addItem(copyAction)

    if fullAttachment.urlPreview?.isVideoPreview != true,
       let photoInfo = fullAttachment.photoInfo,
       hasPhotoPreview(for: photoInfo)
    {
      menu.addItem(NSMenuItem.separator())

      let previewAction = NSMenuItem(
        title: "Quick Look Image",
        action: #selector(openPhotoPreviewFromMenu),
        keyEquivalent: ""
      )
      previewAction.target = self
      previewAction.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
      menu.addItem(previewAction)
    }

    if let exclusionContext = previewExclusionContext() {
      menu.addItem(NSMenuItem.separator())

      let excludeAction = NSMenuItem(
        title: "Never Show Previews for \(exclusionContext.pattern.host)",
        action: #selector(neverShowPreviewFromMenu),
        keyEquivalent: ""
      )
      excludeAction.target = self
      excludeAction.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
      menu.addItem(excludeAction)
    }

    if canRemovePreview {
      menu.addItem(NSMenuItem.separator())

      let removeAction = NSMenuItem(title: "Remove", action: #selector(removePreviewFromMenu), keyEquivalent: "")
      removeAction.target = self
      removeAction.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
      menu.addItem(removeAction)
    }

    return menu
  }

  private func previewExclusionContext() -> SpaceUrlPreviewExclusionContext? {
    guard let previewURL else { return nil }
    return SpaceUrlPreviewExclusionAccess.context(peer: message.peerId, url: previewURL)
  }

  private func removeURLPreviewAttachment() {
    guard let attachmentId = fullAttachment.attachment.attachmentId else {
      Log.shared.error("Missing URL preview attachment id for deletion")
      return
    }

    Task {
      do {
        _ = try await Api.realtime.send(.deleteMessageAttachment(
          peerId: message.peerId,
          messageId: message.messageId,
          attachmentId: attachmentId,
        ))
      } catch {
        Log.shared.error("Failed to remove URL preview attachment", error: error)

        DispatchQueue.main.async { [weak self] in
          self?.showRemoveErrorAlert(error: error)
        }
      }
    }
  }

  private func showRemoveErrorAlert(error: Error) {
    let alert = NSAlert()
    alert.messageText = "Remove Failed"
    alert.informativeText = "Failed to remove the link preview: \(error.localizedDescription)"
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private func showExcludeErrorAlert(error: Error) {
    let alert = NSAlert()
    alert.messageText = "Update Failed"
    alert.informativeText = "Failed to update URL preview settings: \(error.localizedDescription)"
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      QLPreviewPanel.shared()?.updateController()
    }
    return became
  }

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    previewImageURL != nil
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
  }

  deinit {
    clearPreviewImageURL()
  }
}

extension URLPreviewAttachmentView: QLPreviewPanelDataSource {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    previewImageURL == nil ? 0 : 1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    self
  }
}

extension URLPreviewAttachmentView: QLPreviewPanelDelegate {
  func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
    window?.convertToScreen(imageContainer.convert(imageContainer.bounds, to: nil)) ?? .zero
  }

  func previewPanel(
    _ panel: QLPreviewPanel!,
    transitionImageFor item: QLPreviewItem!,
    contentRect: UnsafeMutablePointer<NSRect>!
  ) -> Any! {
    photoView.displayedImage
  }
}

extension URLPreviewAttachmentView: QLPreviewItem {
  var previewItemURL: URL! {
    previewImageURL
  }

  var previewItemTitle: String! {
    titleLabel.stringValue
  }
}

private final class PreviewImageContainerView: NSView {
  var onTap: (() -> Void)?
  var contextMenuProvider: (() -> NSMenu?)?

  override var isFlipped: Bool {
    true
  }

  var hasTapAction: Bool {
    onTap != nil
  }

  private var pressed = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    PressScaleAnimator.prepare(self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      setPressed(false)
    } else {
      PressScaleAnimator.prepare(self)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point), !isHidden else {
      MessageGestureTrace.trace(
        "URLPreviewImageContainer.hitTest point=\(MessageGestureTrace.point(point)) result=nil hasTap=\(onTap != nil) hidden=\(isHidden)"
      )
      return nil
    }

    guard onTap != nil else {
      MessageGestureTrace.trace(
        "URLPreviewImageContainer.hitTest point=\(MessageGestureTrace.point(point)) result=nil hasTap=false"
      )
      return nil
    }

    MessageGestureTrace.trace("URLPreviewImageContainer.hitTest point=\(MessageGestureTrace.point(point)) result=self")
    return self
  }

  override func mouseDown(with event: NSEvent) {
    MessageGestureTrace.debug(
      "URLPreviewImageContainer.mouseDown type=\(event.type.rawValue) clicks=\(event.clickCount) point=\(MessageGestureTrace.point(convert(event.locationInWindow, from: nil))) hasTap=\(onTap != nil)"
    )
    if event.modifierFlags.contains(.control), showContextMenu(with: event) {
      MessageGestureTrace.debug("URLPreviewImageContainer.mouseDown action=contextMenu")
      return
    }

    guard onTap != nil, event.type == .leftMouseDown else {
      MessageGestureTrace.debug("URLPreviewImageContainer.mouseDown forwardingToSuper")
      super.mouseDown(with: event)
      return
    }

    setPressed(true)
    guard let window else {
      MessageGestureTrace.debug("URLPreviewImageContainer.mouseDown noWindow")
      setPressed(false)
      return
    }

    while let next = window.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp],
      until: .distantFuture,
      inMode: .eventTracking,
      dequeue: true
    ) {
      let isInside = bounds.contains(convert(next.locationInWindow, from: nil))
      switch next.type {
      case .leftMouseDragged:
        MessageGestureTrace.trace(
          "URLPreviewImageContainer.mouseDragged inside=\(isInside) point=\(MessageGestureTrace.point(convert(next.locationInWindow, from: nil)))"
        )
        setPressed(isInside)
      case .leftMouseUp:
        setPressed(false)
        if isInside {
          MessageGestureTrace.debug("URLPreviewImageContainer.mouseUp action=onTap")
          onTap?()
        } else {
          MessageGestureTrace.debug("URLPreviewImageContainer.mouseUp cancelledOutside")
        }
        return
      default:
        break
      }
    }

    MessageGestureTrace.debug("URLPreviewImageContainer.mouseDown trackingEndedWithoutMouseUp")
    setPressed(false)
  }

  override func rightMouseDown(with event: NSEvent) {
    MessageGestureTrace.debug(
      "URLPreviewImageContainer.rightMouseDown point=\(MessageGestureTrace.point(convert(event.locationInWindow, from: nil)))"
    )
    if showContextMenu(with: event) {
      MessageGestureTrace.debug("URLPreviewImageContainer.rightMouseDown action=contextMenu")
      return
    }

    super.rightMouseDown(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    contextMenuProvider?() ?? super.menu(for: event)
  }

  private func showContextMenu(with event: NSEvent) -> Bool {
    guard let menu = contextMenuProvider?() else { return false }
    setPressed(false)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
    return true
  }

  private func setPressed(_ pressed: Bool) {
    guard self.pressed != pressed else { return }
    self.pressed = pressed
    alphaValue = pressed ? 0.88 : 1
    PressScaleAnimator.setPressed(pressed, on: self)
  }
}

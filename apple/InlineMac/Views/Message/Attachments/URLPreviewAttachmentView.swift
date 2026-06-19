import AppKit
import InlineKit
import InlineUI
import Logger
import Quartz

final class URLPreviewAttachmentView: NSView, AttachmentView {
  private typealias Layout = URLPreviewAttachmentLayout
  private typealias Mode = URLPreviewAttachmentLayout.Mode

  private(set) var fullAttachment: FullAttachment
  private var message: Message
  private let usesOutgoingBubbleStyle: Bool
  private let mode: Mode

  var attachment: Attachment {
    fullAttachment.attachment
  }

  func canUpdate(with fullAttachment: FullAttachment) -> Bool {
    fullAttachment.urlPreview != nil && Self.mode(for: fullAttachment) == mode
  }

  func update(fullAttachment next: FullAttachment, message: Message) {
    guard canUpdate(with: next) else { return }

    let previousPhotoId = fullAttachment.photoInfo?.id
    fullAttachment = next
    self.message = message
    if previousPhotoId != next.photoInfo?.id {
      clearPreviewImageURL()
    }

    configure()
    updateColors()
  }

  private var previewURL: URL?
  private var previewImageURL: URL?
  private var tempPreviewImageURL: URL?
  private var pressed = false
  private var largeMediaHeightConstraint: NSLayoutConstraint?

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
    view.layer?.cornerRadius = Layout.cornerRadius
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var contentStack: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = mode == .large ? .vertical : .horizontal
    stack.spacing = mode == .large ? Layout.largeSpacing : Layout.spacing
    stack.alignment = mode == .large ? .leading : .centerY
    stack.detachesHiddenViews = true
    return stack
  }()

  private lazy var imageContainer: PreviewImageContainerView = {
    let view = PreviewImageContainerView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = 6
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
    view.layer?.cornerRadius = 6
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var playIconView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.symbolConfiguration = .init(pointSize: Layout.playIconSize, weight: .medium)
    view.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
    view.imageScaling = .scaleProportionallyUpOrDown
    return view
  }()

  private lazy var providerPlaceholderView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.imageScaling = .scaleProportionallyUpOrDown
    view.isHidden = true
    return view
  }()

  private lazy var textStack: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.spacing = Layout.textSpacing
    stack.alignment = .leading
    stack.detachesHiddenViews = true
    stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return stack
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

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = Layout.cornerRadius
    layer?.masksToBounds = true
    translatesAutoresizingMaskIntoConstraints = false
    PressScaleAnimator.prepare(self)
    let verticalPadding = mode == .large ? Layout.largePadding : Layout.compactVerticalPadding
    let leadingPadding = mode == .large ? Layout.largePadding : Layout.compactLeadingPadding
    let trailingPadding = mode == .large ? Layout.largePadding : Layout.compactTrailingPadding

    addSubview(backgroundView)
    addSubview(accentView)
    addSubview(contentStack)

    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      accentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      accentView.topAnchor.constraint(equalTo: topAnchor),
      accentView.bottomAnchor.constraint(equalTo: bottomAnchor),
      accentView.widthAnchor.constraint(equalToConstant: Layout.accentWidth),

      contentStack.leadingAnchor.constraint(equalTo: accentView.trailingAnchor, constant: leadingPadding),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingPadding),
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
    ])

    contentStack.addArrangedSubview(imageContainer)
    contentStack.addArrangedSubview(textStack)

    switch mode {
      case .compact:
        NSLayoutConstraint.activate([
          imageContainer.heightAnchor.constraint(equalTo: textStack.heightAnchor),
          imageContainer.widthAnchor.constraint(equalTo: imageContainer.heightAnchor),
        ])
      case .large:
        largeMediaHeightConstraint = imageContainer.heightAnchor.constraint(
          equalToConstant: 0
        )
        NSLayoutConstraint.activate([
          imageContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
          largeMediaHeightConstraint!,
          textStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }

    imageContainer.addSubview(photoView)
    imageContainer.addSubview(providerPlaceholderView)
    imageContainer.addSubview(playIconView)
    imageContainer.contextMenuProvider = { [weak self] in
      self?.makeContextMenu()
    }

    NSLayoutConstraint.activate([
      photoView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
      photoView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
      photoView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
      photoView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

      providerPlaceholderView.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
      providerPlaceholderView.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
      providerPlaceholderView.widthAnchor.constraint(equalToConstant: Layout.providerPlaceholderSize),
      providerPlaceholderView.heightAnchor.constraint(equalToConstant: Layout.providerPlaceholderSize),

      playIconView.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
      playIconView.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
      playIconView.widthAnchor.constraint(equalToConstant: Layout.playIconSize),
      playIconView.heightAnchor.constraint(equalToConstant: Layout.playIconSize),
    ])

    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(descriptionLabel)

    NSLayoutConstraint.activate([
      titleLabel.widthAnchor.constraint(lessThanOrEqualTo: textStack.widthAnchor),
      descriptionLabel.widthAnchor.constraint(lessThanOrEqualTo: textStack.widthAnchor),
    ])
  }

  private func configure() {
    guard let preview = fullAttachment.urlPreview else { return }

    let isVideo = preview.isVideoPreview
    let display = Layout.displayContent(for: preview, mode: mode)
    previewURL = preview.openURL
    toolTip = preview.title ?? preview.url

    titleLabel.stringValue = display.title
    descriptionLabel.lineBreakMode = mode == .large ? .byWordWrapping : .byTruncatingTail
    descriptionLabel.maximumNumberOfLines = mode == .large ? 0 : 1
    descriptionLabel.stringValue = display.subtitle ?? ""
    descriptionLabel.isHidden = descriptionLabel.stringValue.isEmpty

    setAccessibilityLabel([display.title, display.subtitle].compactMap(\.self).joined(separator: ": "))
    setAccessibilityRole(.group)

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

  func apply(layout: URLPreviewAttachmentLayout.Plan) {
    guard let mediaSize = layout.mediaSize else { return }
    if largeMediaHeightConstraint?.constant != mediaSize.height {
      largeMediaHeightConstraint?.constant = mediaSize.height
    }
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
      if !imageContainer.isHidden, opensLinkOnImage {
        imageContainer.onTap = { [weak self] in
          self?.openPreviewURL()
        }
      }
      return
    }

    imageContainer.isHidden = false
    photoView.isHidden = false
    providerPlaceholderView.isHidden = true
    imageContainer.layer?.backgroundColor = imagePlaceholderBackgroundColor.cgColor
    photoView.showsLoadingPlaceholder = true
    photoView.setPhoto(photoInfo, reloadMessageOnFinish: message)

    if opensLinkOnImage {
      imageContainer.onTap = { [weak self] in
        self?.openPreviewURL()
      }
    } else {
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

  private func updateColors() {
    layer?.backgroundColor = backgroundColor.cgColor
    backgroundView.layer?.backgroundColor = backgroundColor.cgColor
    accentView.layer?.backgroundColor = accentColor.cgColor
    titleLabel.textColor = primaryTextColor
    descriptionLabel.textColor = secondaryTextColor
    playIconView.contentTintColor = secondaryTextColor
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
    guard onTap != nil, bounds.contains(point), !isHidden else {
      let hit = super.hitTest(point)
      MessageGestureTrace.trace(
        "URLPreviewImageContainer.hitTest point=\(MessageGestureTrace.point(point)) result=\(String(describing: hit.map { type(of: $0) })) hasTap=\(onTap != nil) hidden=\(isHidden)"
      )
      return hit
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

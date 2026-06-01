import AppKit
import InlineKit
import InlineUI
import Logger
import Quartz

final class URLPreviewAttachmentView: NSView, AttachmentView, NSGestureRecognizerDelegate {
  private enum Mode {
    case compact
    case large

    var height: CGFloat {
      switch self {
        case .compact:
          return Theme.urlPreviewCompactHeight
        case .large:
          return Theme.urlPreviewLargeHeight
      }
    }
  }

  private enum Constants {
    static let cornerRadius: CGFloat = 8
    static let compactPadding: CGFloat = 2
    static let largePadding: CGFloat = 4
    static let spacing: CGFloat = 7
    static let largeSpacing: CGFloat = 6
    static let accentWidth: CGFloat = 3
    static let playIconSize: CGFloat = 18
    static let largeMediaHeight: CGFloat = 134
  }

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
    view.layer?.cornerRadius = Constants.cornerRadius
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var contentStack: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = mode == .large ? .vertical : .horizontal
    stack.spacing = mode == .large ? Constants.largeSpacing : Constants.spacing
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
    view.symbolConfiguration = .init(pointSize: Constants.playIconSize, weight: .medium)
    view.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
    view.imageScaling = .scaleProportionallyUpOrDown
    return view
  }()

  private lazy var textStack: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.spacing = 2
    stack.alignment = .leading
    stack.detachesHiddenViews = true
    stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return stack
  }()

  private lazy var titleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var descriptionLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 12)
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
    addClickGesture()
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func mode(for fullAttachment: FullAttachment) -> Mode {
    fullAttachment.urlPreview?.isVideoPreview == true ? .large : .compact
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = Constants.cornerRadius
    layer?.masksToBounds = true
    translatesAutoresizingMaskIntoConstraints = false
    let padding = mode == .large ? Constants.largePadding : Constants.compactPadding

    addSubview(backgroundView)
    addSubview(accentView)
    addSubview(contentStack)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: mode.height),

      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      accentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      accentView.topAnchor.constraint(equalTo: topAnchor),
      accentView.bottomAnchor.constraint(equalTo: bottomAnchor),
      accentView.widthAnchor.constraint(equalToConstant: Constants.accentWidth),

      contentStack.leadingAnchor.constraint(equalTo: accentView.trailingAnchor, constant: padding),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
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
        NSLayoutConstraint.activate([
          imageContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
          imageContainer.heightAnchor.constraint(equalToConstant: Constants.largeMediaHeight),
          textStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }

    imageContainer.addSubview(photoView)
    imageContainer.addSubview(playIconView)
    imageContainer.contextMenuProvider = { [weak self] in
      self?.makeContextMenu()
    }

    NSLayoutConstraint.activate([
      photoView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
      photoView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
      photoView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
      photoView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

      playIconView.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
      playIconView.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
      playIconView.widthAnchor.constraint(equalToConstant: Constants.playIconSize),
      playIconView.heightAnchor.constraint(equalToConstant: Constants.playIconSize),
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
    let display = preview.displayContent(maxDescriptionLength: mode == .large ? 420 : 110)
    previewURL = preview.openURL
    toolTip = preview.title ?? preview.url

    titleLabel.stringValue = display.title
    descriptionLabel.lineBreakMode = .byTruncatingTail
    descriptionLabel.maximumNumberOfLines = 1
    descriptionLabel.stringValue = display.subtitle ?? ""
    descriptionLabel.isHidden = descriptionLabel.stringValue.isEmpty

    setAccessibilityLabel([display.title, display.subtitle].compactMap(\.self).joined(separator: ": "))
    setAccessibilityRole(.group)

    playIconView.isHidden = !isVideo
    configureImage(showPlaceholder: isVideo, opensLinkOnImage: isVideo)
  }

  private func configureImage(showPlaceholder: Bool, opensLinkOnImage: Bool) {
    imageContainer.onTap = nil

    guard let photoInfo = fullAttachment.photoInfo else {
      clearPreviewImageURL()
      imageContainer.isHidden = !showPlaceholder
      photoView.showsLoadingPlaceholder = showPlaceholder
      photoView.setPhoto(nil)
      if showPlaceholder, opensLinkOnImage {
        imageContainer.onTap = { [weak self] in
          self?.openPreviewURL()
        }
      }
      return
    }

    imageContainer.isHidden = false
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

  private func addClickGesture() {
    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
    clickGesture.delaysPrimaryMouseButtonEvents = false
    clickGesture.delegate = self
    addGestureRecognizer(clickGesture)
    MessageGestureTrace.debug("URLPreviewAttachmentView.addClickGesture")
  }

  @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
    MessageGestureTrace.debug(
      "URLPreviewAttachmentView.handleClick state=\(gesture.state.rawValue) point=\(MessageGestureTrace.point(gesture.location(in: self))) imageHasTap=\(imageContainer.hasTapAction)"
    )
    if imageContainer.hasTapAction {
      let location = convert(gesture.location(in: self), to: imageContainer)
      guard !imageContainer.bounds.contains(location) else {
        MessageGestureTrace.debug(
          "URLPreviewAttachmentView.handleClick blocked=imageTapArea local=\(MessageGestureTrace.point(location))"
        )
        return
      }
    }

    MessageGestureTrace.debug("URLPreviewAttachmentView.handleClick action=openPreviewURL")
    openPreviewURL()
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
      PressScaleAnimator.prepare(imageContainer)
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

    MessageGestureTrace.trace("URLPreviewAttachmentView.mouseDown forwardingToSuper")
    super.mouseDown(with: event)
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

  func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
    let result = shouldHandleCardGesture(event: event)
    MessageGestureTrace.debug(
      "URLPreviewAttachmentView.delegate.shouldAttempt recognizer=\(type(of: gestureRecognizer)) type=\(event.type.rawValue) clicks=\(event.clickCount) allow=\(result)"
    )
    return result
  }

  private func shouldHandleCardGesture(event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else {
      MessageGestureTrace.debug(
        "URLPreviewAttachmentView.shouldHandleCardGesture allow=false reason=eventOrControl type=\(event.type.rawValue) modifiers=\(event.modifierFlags.rawValue)"
      )
      return false
    }

    guard imageContainer.hasTapAction else {
      MessageGestureTrace.debug("URLPreviewAttachmentView.shouldHandleCardGesture allow=true reason=noImageTap")
      return true
    }
    let location = convert(event.locationInWindow, from: nil)
    let imageLocation = convert(location, to: imageContainer)
    let allow = !imageContainer.bounds.contains(imageLocation)
    MessageGestureTrace.debug(
      "URLPreviewAttachmentView.shouldHandleCardGesture allow=\(allow) point=\(MessageGestureTrace.point(location)) imagePoint=\(MessageGestureTrace.point(imageLocation)) reason=imageTapArea"
    )
    return allow
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    makeContextMenu() ?? super.menu(for: event)
  }

  private func showContextMenu(with event: NSEvent) -> Bool {
    guard let menu = makeContextMenu() else { return false }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
    return true
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

    if canRemovePreview {
      menu.addItem(NSMenuItem.separator())

      let removeAction = NSMenuItem(title: "Remove", action: #selector(removePreviewFromMenu), keyEquivalent: "")
      removeAction.target = self
      removeAction.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
      menu.addItem(removeAction)
    }

    return menu
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

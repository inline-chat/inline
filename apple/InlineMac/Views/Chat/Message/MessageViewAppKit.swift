// MessageView.swift
import AppKit
import Foundation
import InlineKit
import InlineUI
import Logger
import Nuke
import NukeUI
import SwiftUI
import Throttler

class MessageViewAppKit: NSView {
  private let feature_relayoutOnBoundsChange = true

  static let avatarSize: CGFloat = Theme.messageAvatarSize
  private var fullMessage: FullMessage
  private var props: MessageViewProps
  private var from: User {
    fullMessage.from ?? User.deletedInstance
  }

  private var message: Message {
    fullMessage.message
  }

  private var showsAvatar: Bool { props.layout.hasAvatar }
  private var showsName: Bool { props.layout.hasName }
  private var outgoing: Bool {
    message.out == true
  }

  private var hasLegacyPhoto: Bool {
    if let file = fullMessage.file, file.fileType == .photo {
      return true
    }
    return false
  }

  private var hasPhoto: Bool {
    props.layout.hasPhoto
  }

  private var hasVideo: Bool {
    false
  }

  private var hasDocument: Bool {
    props.layout.hasDocument
  }

  private var hasReply: Bool {
    props.layout.hasReply
  }

  private var hasText: Bool {
    props.layout.hasText
  }

  private var textWidth: CGFloat {
    props.layout.text?.size.width ?? 1.0
  }

  private var contentWidth: CGFloat {
    props.layout.bubble.size.width
  }

  private var textColor: NSColor {
    if outgoing {
      NSColor.white
    } else {
      NSColor.labelColor
    }
  }

  private var bubbleBackgroundColor: NSColor {
    if outgoing {
      Theme.messageBubblePrimaryBgColor
    } else {
      Theme.messageBubbleSecondaryBgColor
    }
  }

  private var linkColor: NSColor {
    if outgoing {
      NSColor.white
    } else {
      NSColor.linkColor
    }
  }

  private var senderFont: NSFont {
    .systemFont(
      ofSize: 12, // NSFont.smallSystemFontSize
      weight: .semibold
    )
  }

  // State
  private var isMouseInside = false

  // MARK: Views

  private lazy var bubbleView: BasicView = {
    let view = BasicView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.cornerRadius = Theme.messageBubbleCornerRadius
    view.backgroundColor = bubbleBackgroundColor
    return view
  }()

  private lazy var avatarView: UserAvatarView = {
    let view = UserAvatarView(userInfo: fullMessage.senderInfo ?? .deleted)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var nameLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = senderFont
    label.lineBreakMode = .byTruncatingTail

    return label
  }()

  private lazy var contentView: NSStackView = {
    let view = NSStackView()
    view.spacing = 0.0 // don't use this, use spacer views
    view.orientation = .vertical
    view.translatesAutoresizingMaskIntoConstraints = false
    view.alignment = .leading
    view.distribution = .fill
    return view
  }()

  private lazy var timeAndStateView: MessageTimeAndState = {
    let view = MessageTimeAndState(fullMessage: fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    return view
  }()

  private lazy var newPhotoView: NewPhotoView = {
    let view = NewPhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var documentView: DocumentView? = {
    guard let documentInfo = fullMessage.documentInfo else { return nil }

    let view = DocumentView(
      documentInfo: documentInfo,
      fullMessage: self.fullMessage
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var replyView: EmbeddedMessageView = {
    let view = EmbeddedMessageView(kind: .replyInMessage, style: outgoing ? .white : .colored)
    view.translatesAutoresizingMaskIntoConstraints = false
    if let message = fullMessage.repliedToMessage, let from = fullMessage.replyToMessageSender {
      view.update(with: message, from: from, file: fullMessage.replyToMessageFile)
    }
    return view
  }()

  private var useTextKit2: Bool = true

  /// Wraps text and helps with layout
  private lazy var textViewWrapper: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    return view
  }()

  private lazy var textView: NSTextView = {
    let textView = if useTextKit2 {
      MessageTextView(usingTextLayoutManager: true) // Experimental text kit 2
    } else {
      MessageTextView(usingTextLayoutManager: false) // TextKit 1
    }

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    // Clips to bounds = false fucks up performance so badly. what!?
    textView.clipsToBounds = true
    textView.textContainerInset = MessageTextConfiguration.containerInset
    textView.font = MessageTextConfiguration.font
    textView.textColor = textColor

    let textContainer = textView.textContainer
    textContainer?.widthTracksTextView = true
    textContainer?.heightTracksTextView = true

    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false

    textView.delegate = self

    // In NSTextView you need to customize link colors here otherwise the attributed string for links
    // does not have any effect.
    textView.linkTextAttributes = [
      .foregroundColor: linkColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
      .cursor: NSCursor.pointingHand,
    ]

    // Match the sizes and spacing with the size calculator we use to calculate cell height
    MessageTextConfiguration.configureTextContainer(textContainer!)
    MessageTextConfiguration.configureTextView(textView)

    return textView
  }()

  // MARK: - Initialization

  init(fullMessage: FullMessage, props: MessageViewProps) {
    self.fullMessage = fullMessage
    self.props = props
    super.init(frame: .zero)
    setupView()

    DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
      self?.addHoverTrackingArea()
      self?.setupScrollStateObserver()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func layout() {
    super.layout()
  }

  override func updateConstraints() {
    super.updateConstraints()
  }

  // MARK: - Setup

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let observer = notificationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func setupView() {
    // For performance of animations
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.drawsAsynchronously = true

    addSubview(bubbleView)

    addSubview(timeAndStateView)

    if showsAvatar {
      addSubview(avatarView)
    }

    if showsName {
      addSubview(nameLabel)
      let name = from.firstName ?? from.username ?? ""
      let nameForInitials = UserAvatar.getNameForInitials(user: from)
      nameLabel.stringValue = outgoing ? "You" : name
      nameLabel.textColor = NSColor(
        InitialsCircle.ColorPalette
          .color(for: nameForInitials)
      )
    }

    addSubview(contentView)

    if hasReply {
      contentView.addArrangedSubview(replyView)
    }

    if hasPhoto {
      contentView.addArrangedSubview(newPhotoView)
    }

    if hasDocument, let documentView {
      contentView.addArrangedSubview(documentView)
    }

    if hasText {
      contentView.addArrangedSubview(textView)
    }

    setupMessageText()
    setupConstraints()
    setupContextMenu()
  }

  private var textViewWidthConstraint: NSLayoutConstraint?
  private var textViewHeightConstraint: NSLayoutConstraint?
  private var photoViewHeightConstraint: NSLayoutConstraint?
  private var photoViewWidthConstraint: NSLayoutConstraint?
  private var contentViewWidthConstraint: NSLayoutConstraint!
  private var bubbleViewWidthConstraint: NSLayoutConstraint!
  private var bubbleViewHeightConstraint: NSLayoutConstraint!

  private func setupConstraints() {
    var constraints: [NSLayoutConstraint] = []
    let layout = props.layout

    defer {
      NSLayoutConstraint.activate(constraints)
    }

    // Note:
    // There shouldn't be any calculations of sizes or spacing here. All of it must be off-loaded to SizeCalculator
    // and stored in the layout plan.

    // Content View Top and Bottom Insets
    contentView.edgeInsets = NSEdgeInsets(
      top: layout.topMostContentTopSpacing,
      left: 0,
      bottom: layout.bottomMostContentBottomSpacing,
      right: 0
    )

    if let avatar = layout.avatar {
      constraints.append(
        contentsOf: [
          avatarView.leadingAnchor
            .constraint(equalTo: leadingAnchor, constant: avatar.spacing.left),
          avatarView.topAnchor
            .constraint(
              equalTo: topAnchor,
              constant: avatar.spacing.top + layout.wrapper.spacing.top
            ),
          avatarView.widthAnchor.constraint(equalToConstant: avatar.size.width),
          avatarView.heightAnchor.constraint(equalToConstant: avatar.size.height),
        ]
      )
    }

    if let name = layout.name {
      constraints.append(
        contentsOf: [
          nameLabel.leadingAnchor
            .constraint(
              equalTo: leadingAnchor,
              constant: layout.nameAndBubbleLeading + name.spacing.left
            ),
          nameLabel.topAnchor
            .constraint(equalTo: topAnchor, constant: layout.wrapper.spacing.top),
          nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
          nameLabel.heightAnchor
            .constraint(equalToConstant: name.size.height),
        ]
      )
    }

    // Bubble And Content View

    if layout.hasName {
      // if we have name, attach bubble to it
      constraints.append(contentsOf: [
        bubbleView.topAnchor.constraint(
          equalTo: nameLabel.bottomAnchor
        ),
        contentView.topAnchor.constraint(
          equalTo: nameLabel.bottomAnchor
        ),
      ])

    } else {
      // otherwise attach to top
      constraints.append(contentsOf: [
        bubbleView.topAnchor.constraint(
          equalTo: topAnchor,
          constant: layout.wrapper.spacing.top
        ),
        contentView.topAnchor.constraint(
          equalTo: topAnchor,
          constant: layout.wrapper.spacing.top
        ),
      ])
    }

    bubbleViewHeightConstraint = bubbleView.heightAnchor.constraint(equalToConstant: layout.bubble.size.height)
    bubbleViewWidthConstraint = bubbleView.widthAnchor.constraint(
      equalToConstant: layout.bubble.size.width
    )
    contentViewWidthConstraint = contentView.widthAnchor.constraint(equalToConstant: layout.bubble.size.width)

    constraints.append(
      contentsOf: [
        bubbleViewHeightConstraint,
        bubbleViewWidthConstraint,
        bubbleView.leadingAnchor
          .constraint(
            equalTo: leadingAnchor,
            constant: layout.nameAndBubbleLeading
          ),

        contentViewWidthConstraint,
        contentView.leadingAnchor
          .constraint(
            equalTo: leadingAnchor,
            constant: layout.nameAndBubbleLeading
          ),
      ]
    )

    // Text

    if let text = layout.text {
      textViewWidthConstraint = textView.widthAnchor
        .constraint(equalToConstant: text.size.width)
      textViewHeightConstraint = textView.heightAnchor
        .constraint(equalToConstant: text.size.height)

      constraints.append(
        contentsOf: [
          textViewHeightConstraint!,
          textViewWidthConstraint!,
          textView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: text.spacing.left
          ),
        ]
      )

      contentView.setCustomSpacing(text.spacing.bottom, after: textView)

      // TODO: Handle RTL
    }

    // Time
    if let time = layout.time {
      constraints.append(
        contentsOf: [
          timeAndStateView.widthAnchor.constraint(
            equalToConstant: time.size.width
          ),
          timeAndStateView.heightAnchor.constraint(
            equalToConstant: time.size.height
          ),
          timeAndStateView.trailingAnchor
            .constraint(
              equalTo: bubbleView.trailingAnchor,
              constant: -time.spacing.right
            ),
          timeAndStateView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -time.spacing.bottom),
        ]
      )
    }

    if let reply = layout.reply {
      constraints.append(
        contentsOf: [
          replyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: reply.spacing.left),
          replyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -reply.spacing.right),
        ]
      )
      contentView.setCustomSpacing(reply.spacing.bottom, after: replyView)
    }

    // Photo

    if let photo = layout.photo {
      photoViewHeightConstraint = newPhotoView.heightAnchor.constraint(equalToConstant: photo.size.height)
      photoViewWidthConstraint = newPhotoView.widthAnchor
        .constraint(greaterThanOrEqualToConstant: photo.size.width)
      constraints.append(contentsOf: [
        photoViewHeightConstraint!,
        photoViewWidthConstraint!,
      ])
      contentView.setCustomSpacing(photo.spacing.bottom, after: newPhotoView)
    }
  }

  private func setupMessageText() {
    guard hasText else {
      return
    }

    // Setup text
    let text = message.text ?? ""

    textView.baseWritingDirection = props.isRtl ? .rightToLeft : .natural

    if let attrs = CacheAttrs.shared.get(message: message) {
      textView.textStorage?.setAttributedString(attrs)
      return
    }

    // Create mutable attributed string
    let attributedString = NSMutableAttributedString(
      // Trim to avoid known issue with size calculator
      string: text, // .trimmingCharacters(in: .whitespacesAndNewlines),
      attributes: [
        .font: MessageTextConfiguration.font,
        .foregroundColor: textColor,
      ]
    )

    // Detect and add links
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    if let detector {
      let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))

      for match in matches {
        if let url = match.url {
          attributedString.addAttributes([
            .cursor: NSCursor.pointingHand,
            .link: url,
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
          ], range: match.range)
        }
      }
    }

    textView.textStorage?.setAttributedString(attributedString)

    CacheAttrs.shared.set(message: message, value: attributedString)
  }

  func reflectBoundsChange(fraction uncappedFraction: CGFloat) {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if window != nil {
      // Register for scroll visibility notifications
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleBoundsChange),
        name: NSView.boundsDidChangeNotification,
        object: enclosingScrollView?.contentView
//        name: NSView.frameDidChangeNotification,
//        object: enclosingScrollView?.contentView
      )
    }
  }

  private var prevWidth: CGFloat = 0

  // Fix a bug that when messages were out of viewport and came back during a live resize
  // text would not appear until the user ended live resize operation. Seems like in TextKit 2 calling layoutViewport
  // solves this.
  // The property `allowsNonContiguousLayout` also seems to fix this issue but it has two other issues:
  // 1. that forces textkit 1
  // 2. it adds a scroll jump everytime user resizes the window
  // which made it unsusable.
  // This approach still needs further testing.
  @objc private func handleBoundsChange(_ notification: Notification) {
    guard feature_relayoutOnBoundsChange else { return }
    guard let scrollView = enclosingScrollView,
          let clipView = notification.object as? NSClipView else { return }

//    if prevWidth != 0 && prevWidth != bounds.width {
//      // skip if width changed bc we are handling relayout in updatePropsAndUpdateLayout and causes flicker
//      Log.shared.debug("Skipping relayout because width didn't change")
//      return
//    }
//
//    prevWidth = bounds.width

    let visibleRect = scrollView.documentVisibleRect

    let frameInClipView = convert(bounds, to: clipView)

    if visibleRect
      // Limit the layout to the top 30 points of viewport so we minimize number of messages that are layouted
      // TODO: we need to eventually find a more optimized version of this
      .divided(atDistance: 30.0, from: .minYEdge).slice
      .intersects(frameInClipView)
    {
      // Only do this during live resize
      if !textView.inLiveResize {
        return
      }

      if !hasText {
        return
      }

//      if isOverMaxWidth {
//        didTextLayoutAfterMaxWidth = true
//      }

      if useTextKit2 {
        // TextKit 2 specific configuration
        if let textLayoutManager = textView.textLayoutManager {
          // Choose based on multiline vs single line
          if !props.layout.singleLine {
            // Important note:
            // Less performant, but fixes flicker during live resize for large messages that are beyound viewport height
            // and during width resize
            Log.shared.debug("Layouting viewport (1) for text view \(message.id) ")

            textLayoutManager.textViewportLayoutController.layoutViewport()
            textView.layout()
            textView.display()
          } else {
            // More performant for single line messages
            throttle(.milliseconds(200), identifier: "layoutMessageTextView", by: .mainActor, option: .default) { [
              weak self,
              weak textLayoutManager
            ] in
              guard let self else { return }
              guard let textLayoutManager else { return }

              Log.shared.debug("Layouting viewport for text view \(message.id)")
              textLayoutManager.textViewportLayoutController.layoutViewport()
              textView.layout()
              textView.display()
            }
          }
        }
      } else {
        //        Log.shared.debug("Layouting viewport for text view \(message.id)")

        // TODO: Ensure layout for textkit 1
        // textView.layoutManager?.ensureLayout(for: textView.textContainer!)
      }
    }
  }

  // MARK: - Context Menu

  private func setupContextMenu() {
    let menu = NSMenu()

    #if DEBUG
    let idItem = NSMenuItem(title: "ID: \(message.id)", action: nil, keyEquivalent: "")
    idItem.isEnabled = false
    menu.addItem(idItem)

    let indexItem = NSMenuItem(
      // TODO: debug why it's nil sometimes
      title: "Index: \(props.index?.description ?? "?")",
      action: nil,
      keyEquivalent: ""
    )
    indexItem.isEnabled = false
    menu.addItem(indexItem)
    #endif

    let replyItem = NSMenuItem(title: "Reply", action: #selector(reply), keyEquivalent: "r")
    menu.addItem(replyItem)

    if hasText {
      let copyItem = NSMenuItem(title: "Copy", action: #selector(copyMessage), keyEquivalent: "c")
      menu.addItem(copyItem)
    }

    if hasPhoto {
      let saveItem = NSMenuItem(title: "Save Image", action: #selector(newPhotoView.saveImage), keyEquivalent: "m")
      saveItem.target = newPhotoView
      saveItem.isEnabled = true
      menu.addItem(saveItem)

      let copyItem = NSMenuItem(title: "Copy Image", action: #selector(newPhotoView.copyImage), keyEquivalent: "i")
      copyItem.target = newPhotoView
      copyItem.isEnabled = true
      menu.addItem(copyItem)
    }

    // Add document-related menu items
    if hasDocument {
      let saveDocumentItem = NSMenuItem(title: "Save Document", action: #selector(saveDocument), keyEquivalent: "s")
      menu.addItem(saveDocumentItem)
    }

    let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteMessage), keyEquivalent: "i")
    deleteItem.target = self
    deleteItem.isEnabled = true
    menu.addItem(deleteItem)

    menu.delegate = self
    self.menu = menu
  }

  @objc private func copyMessage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.text ?? "", forType: .string)
  }

  @objc private func deleteMessage() {
    let _ = Transactions.shared.mutate(
      transaction: .deleteMessage(
        .init(
          messageIds: [message.messageId],
          peerId: message.peerId,
          chatId: message.chatId
        )
      )
    )
  }

  @objc private func reply() {
    let state = ChatsManager
      .get(
        for: fullMessage.peerId,
        chatId: fullMessage.chatId
      )

    state.setReplyingToMsgId(fullMessage.message.messageId)
  }

  @objc private func saveDocument() {
    guard let documentInfo = fullMessage.documentInfo else { return }

    // Get the source file URL
    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    guard let localPath = documentInfo.document.localPath else { return }
    let sourceURL = cacheDirectory.appendingPathComponent(localPath)

    // Get the Downloads directory
    let fileManager = FileManager.default
    let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    // Get the filename
    let fileName = documentInfo.document.fileName ?? "Unknown File"

    // Create a save panel
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = fileName
    savePanel.directoryURL = downloadsURL
    savePanel.canCreateDirectories = true

    savePanel.beginSheetModal(for: window!) { response in
      if response == .OK, let destinationURL = savePanel.url {
        do {
          try fileManager.copyItem(at: sourceURL, to: destinationURL)
          NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
          print("Error saving document: \(error)")
        }
      }
    }
  }

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    // Apply selection style when menu is about to open
    layer?.backgroundColor = NSColor.darkGray
      .withAlphaComponent(0.05).cgColor
  }

  override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
    // Remove selection style when menu closes
    layer?.backgroundColor = nil
  }

  // MARK: - View Updates

  private func updatePropsAndUpdateLayout(props: MessageViewProps, disableTextRelayout: Bool = false) {
    // save for comparison
    let prevProps = self.props

    // update internal props (must update so contentView is recalced)
    self.props = props

    // less granular
    // guard props != self.props else { return }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false

      // will help?
      CATransaction.begin()
      CATransaction.setDisableActions(true)

      defer {
        CATransaction.commit()
      }

      if prevProps.layout.bubble != props.layout.bubble {
        contentViewWidthConstraint.constant = props.layout.bubble.size.width
        bubbleViewWidthConstraint.constant = props.layout.bubble.size.width
        bubbleViewHeightConstraint.constant = props.layout.bubble.size.height
      }

      let hasTextSizeChanged =
        prevProps.layout.text != props.layout.text
      let hasPhotoSizeChanged =
        prevProps.layout.photo != props.layout.photo
      let singleLineChanged =
        prevProps.layout.singleLine != props.layout.singleLine

      if singleLineChanged {
        // TODO: Update time position
      }

      // only proceed if text size or photo size has changed
      // Fun fact: I wasted too much time on || being &&
      guard hasTextSizeChanged || hasPhotoSizeChanged
      else { return }

      // # Update sizes
      // Text
      if let text = props.layout.text {
        textViewWidthConstraint?.constant = text.size.width

        // Text size
        if hasTextSizeChanged {
          textViewHeightConstraint?.constant = text.size.height

          // This helps refresh the layout for textView
          textView.textContainer?.containerSize = CGSize(width: text.size.width, height: text.size.height)

          // very subtle fix:
          // ensure the change is reflected even if it was offscreen when live resize started
          if useTextKit2, !disableTextRelayout {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            textView.layout()
            textView.display()
          }
        }
      }

      // photo size
      if hasPhotoSizeChanged,
         let photoViewHeightConstraint,
         let photoViewWidthConstraint,
         let photo = props.layout.photo
      {
        photoViewHeightConstraint.constant = photo.size.height
        photoViewWidthConstraint.constant = photo.size.width
      }
    }
  }

  public func updateTextAndSize(fullMessage: FullMessage, props: MessageViewProps) {
    // update internal props
    self.fullMessage = fullMessage

    // Update props and reflect changes
    updatePropsAndUpdateLayout(props: props, disableTextRelayout: true)

    // Text
    setupMessageText()

    // Photo
    if hasPhoto {
      newPhotoView.update(with: fullMessage)
    }

    // Document
    if hasDocument, let documentView {
      if let documentInfo = fullMessage.documentInfo {
        documentView.update(with: documentInfo)
      }
    }

    // Update time and state
    timeAndStateView.updateMessage(fullMessage)

    DispatchQueue.main.async(qos: .utility) { [weak self] in
      // As the message changes here, we need to update everything related to that. Otherwise we get wrong context menu.
      self?.setupContextMenu()
    }
  }

  public func updateSize(props: MessageViewProps) {
    // update props and reflect changes
    updatePropsAndUpdateLayout(
      props: props,
      disableTextRelayout: props.layout.singleLine // Quick hack to reduce such re-layouts
    )
  }

  private func setTimeAndStateVisibility(visible: Bool) {
//    NSAnimationContext.runAnimationGroup { context in
//      context.duration = visible ? 0.05 : 0.05
//      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
//      context.allowsImplicitAnimation = true
//      timeAndStateView.layer?.opacity = visible ? 1 : 0
//    }
  }

  // MARK: - Actions

  // ---
  private var notificationObserver: NSObjectProtocol?
  private var scrollState: MessageListScrollState = .idle
  private var hoverTrackingArea: NSTrackingArea?
  private func setupScrollStateObserver() {
    notificationObserver = NotificationCenter.default.addObserver(
      forName: .messageListScrollStateDidChange,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let state = notification.userInfo?["state"] as? MessageListScrollState else { return }
      self?.handleScrollStateChange(state)
    }
  }

  // MARK: - Swipe to Reply

  // Track swipe state
  private var isSwipeInProgress = false
  private var swipeOffset: CGFloat = 0
  private var swipeAnimationView: NSView?
  private var hasTriggerHapticFeedback = false
  private var swipeThreshold: CGFloat = 50.0
  private var didReachThreshold = false

  override func scrollWheel(with event: NSEvent) {
    // Only handle horizontal scrolling with two fingers
    if event.phase == .began, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
      // Start of a horizontal scroll
      isSwipeInProgress = true
      swipeOffset = 0
      hasTriggerHapticFeedback = false
      didReachThreshold = false

      // Create animation view if needed
      if swipeAnimationView == nil {
        swipeAnimationView = createReplyIndicator()
        addSubview(swipeAnimationView!)
        swipeAnimationView?.alphaValue = 0
      }

      // Position the animation view
      if let animView = swipeAnimationView {
        let yPosition = bubbleView.bounds.midY - animView.bounds.height / 2
        animView.frame.origin = NSPoint(x: bounds.width - animView.bounds.width - 10, y: yPosition)
      }
    }

    if isSwipeInProgress {
      // Update swipe offset based on scroll delta
      // Note: scrollingDeltaX is positive for right-to-left swipes on some systems
      // We need to ensure we're getting a negative value for left swipes
      let deltaX = event.scrollingDeltaX

      // Adjust the swipe offset - we want negative values for left swipes
      swipeOffset += deltaX

      // Only handle left swipes (negative swipeOffset)
      if swipeOffset < 0 {
        // Calculate swipe progress (0 to 1)
        let progress = min(1.0, abs(swipeOffset) / swipeThreshold)

        // Update position using layer transform on self
        let maxOffset: CGFloat = 40.0
        let offset = -min(maxOffset, abs(swipeOffset)) // Negative for left movement

        // Apply transform to root view layer
        wantsLayer = true
        let transform = CATransform3DMakeTranslation(offset, 0, 0)
        layer?.transform = transform

        // Update animation view
        swipeAnimationView?.alphaValue = progress

        // Track if we've reached the threshold
        let hasReachedThreshold = abs(swipeOffset) > swipeThreshold

        // Only trigger haptic feedback when first crossing the threshold
        if hasReachedThreshold, !didReachThreshold {
          NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
          didReachThreshold = true
          hasTriggerHapticFeedback = true
        } else if !hasReachedThreshold, didReachThreshold {
          // We've moved back below the threshold
          didReachThreshold = false
        }
      } else {
        // Reset for right swipes
        layer?.transform = CATransform3DIdentity
        swipeAnimationView?.alphaValue = 0
      }

      // End of swipe gesture
      if event.phase == .ended || event.phase == .cancelled {
        isSwipeInProgress = false

        // Check if swipe was far enough to trigger reply
        if abs(swipeOffset) > swipeThreshold {
          Task(priority: .userInitiated) { @MainActor in self.reply() }

          // Animate back with spring effect
          NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.layer?.transform = CATransform3DIdentity
            swipeAnimationView?.animator().alphaValue = 0
          }) {}
        } else {
          // Not far enough, just animate back
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.layer?.transform = CATransform3DIdentity
            swipeAnimationView?.animator().alphaValue = 0
          }
        }

        // Reset state
        hasTriggerHapticFeedback = false
        didReachThreshold = false
      }
    } else {
      // Pass the event to super if we're not handling it
      super.scrollWheel(with: event)
    }
  }

  private func createReplyIndicator() -> NSView {
    // Create a smaller indicator (24x24 pixels)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    container.wantsLayer = true
    container.layer?.cornerRadius = 12
    container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor

    // Add reply icon (smaller size)
    let iconView = NSImageView(frame: NSRect(x: 4, y: 4, width: 16, height: 16))
    if let replyImage = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: "Reply") {
      iconView.image = replyImage
      iconView.contentTintColor = NSColor.controlAccentColor
      container.addSubview(iconView)
    }

    return container
  }
}

// MARK: - Tracking Area & Hover

extension MessageViewAppKit {
  private func handleScrollStateChange(_ state: MessageListScrollState) {
    scrollState = state
    switch state {
      case .scrolling:
        // Clear hover state
        updateHoverState(false)
      case .idle:
        // Re-enable hover state if needed
        // TODO: How can I check if mouse is inside the view?
        addHoverTrackingArea()
    }
  }

  var shouldAlwaysShowTimeAndState: Bool {
    message.status == .sending || message.status == .failed
  }

  private func updateHoverState(_ isHovered: Bool) {
    isMouseInside = isHovered
  }

  func removeHoverTrackingArea() {
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
  }

  func addHoverTrackingArea() {
    removeHoverTrackingArea()
    hoverTrackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(hoverTrackingArea!)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard scrollState == .idle else { return }
    updateHoverState(true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    updateHoverState(false)
  }
}

extension MessageViewAppKit: NSTextViewDelegate {}
extension MessageViewAppKit: NSMenuDelegate {}

struct MessageViewInputProps: Equatable, Codable, Hashable {
  var firstInGroup: Bool
  var isLastMessage: Bool
  var isFirstMessage: Bool
  var isRtl: Bool

  /// Used in cache key
  func toString() -> String {
    "\(firstInGroup ? "FG" : "")\(isLastMessage == true ? "LM" : "")\(isFirstMessage == true ? "FM" : "")\(isRtl ? "RTL" : "")"
  }
}

struct MessageViewProps: Equatable, Codable, Hashable {
  var firstInGroup: Bool
  var isLastMessage: Bool
  var isFirstMessage: Bool
  var isRtl: Bool
  var index: Int?
  var layout: MessageSizeCalculator.LayoutPlans

  func equalExceptSize(_ rhs: MessageViewProps) -> Bool {
    firstInGroup == rhs.firstInGroup &&
      isLastMessage == rhs.isLastMessage &&
      isFirstMessage == rhs.isFirstMessage &&
      isRtl == rhs.isRtl
  }
}

// Helper extension for constraint priorities
private extension NSLayoutConstraint {
  func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
    self.priority = priority
    return self
  }
}

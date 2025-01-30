// MessageView.swift
import AppKit
import Foundation
import InlineKit
import InlineUI
import Nuke
import NukeUI
import SwiftUI
import Throttler

class MessageViewAppKit: NSView {
  static let avatarSize: CGFloat = Theme.messageAvatarSize
  private var fullMessage: FullMessage
  private var props: MessageViewProps
  private var from: User {
    fullMessage.from ?? User.deletedInstance
  }

  private var showsAvatar: Bool { props.firstInGroup }
  private var showsName: Bool { props.firstInGroup }
  private var message: Message {
    fullMessage.message
  }

  private var outgoing: Bool {
    message.out == true
  }

  private var hasPhoto: Bool {
    if let file = fullMessage.file, file.fileType == .photo {
      return true
    }
    return false
  }

  private var textWidth: CGFloat {
    props.textWidth ?? 100.0
  }

  // When we have photo, shorter text shouldn't shrink content view
  private var contentWidth: CGFloat {
    props.photoWidth ?? textWidth
  }

  private var textColor: NSColor {
    NSColor.labelColor
  }

  private var linkColor: NSColor {
    NSColor.linkColor
  }

  private var senderFont: NSFont {
    .systemFont(
      ofSize: NSFont.systemFontSize,
      weight: .medium
    )
  }

  // State
  private var isMouseInside = false

  // MARK: Views

  private lazy var avatarView: UserAvatarView = {
    let view = UserAvatarView(user: self.from)
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

  private lazy var underTextSpacer: NSView = {
    let spacerView = NSView()
    spacerView.translatesAutoresizingMaskIntoConstraints = false
    return spacerView
  }()

  private lazy var aboveTextSpacer: NSView = {
    let spacerView = NSView()
    spacerView.translatesAutoresizingMaskIntoConstraints = false
    return spacerView
  }()

  private lazy var timeAndStateView: MessageTimeAndState = {
    let view = MessageTimeAndState(fullMessage: fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true

    view.layer?.opacity = 0
    return view
  }()

  private lazy var photoView: PhotoView = {
    let view = PhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var useTextKit2: Bool = true

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

  // Experimental: See if it looks good or has any performance bottlenecks
  // Update color reflecting the scroll
  func reflectBoundsChange(fraction uncappedFraction: CGFloat) {
    // Disabled until I can make it more stable
//    let fraction = max(0.0, min(1.0, uncappedFraction))
//    if hasBubble {
//      bubbleView.backgroundColor = bubbleColor
//        .blended(withFraction: (1.0 - fraction) * 0.3, of: .white)
//    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if window != nil {
      // Register for scroll visibility notifications
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleBoundsChange),
        name: NSView.boundsDidChangeNotification,
        object: enclosingScrollView?.contentView
      )
    }
  }

  // Fix a bug that when messages were out of viewport and came back during a live resize
  // text would not appear until the user ended live resize operation. Seems like in TextKit 2 calling layoutViewport
  // solves this.
  // The property `allowsNonContiguousLayout` also seems to fix this issue but it has two other issues:
  // 1. that forces textkit 1
  // 2. it adds a scroll jump everytime user resizes the window
  // which made it unsusable.
  // This approach still needs further testing.
  @objc private func handleBoundsChange(_ notification: Notification) {
    guard let scrollView = enclosingScrollView,
          let clipView = notification.object as? NSClipView else { return }

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

      if useTextKit2 {
        // TextKit 2 specific configuration
        if let textLayoutManager = textView.textLayoutManager {
          let naiveThresholdForMultiLine: CGFloat = 50

          // Choose based on multiline vs single line
          if (props.textHeight ?? 0.0) > naiveThresholdForMultiLine {
            // Important note:
            // Less performant, but fixes flicker during live resize for large messages that are beyound viewport height
            // and during width resize
            Log.shared.debug("Layouting viewport for text view \(message.id)")
            textLayoutManager.textViewportLayoutController.layoutViewport()
          } else {
            // More performant
            throttle(.milliseconds(100), identifier: "layoutMessageTextView", by: .mainActor, option: .default) { [
              weak self,
              weak textLayoutManager
            ] in
              guard let self else { return }
              guard let textLayoutManager else { return }

              Log.shared.debug("Layouting viewport for text view \(message.id)")
              textLayoutManager.textViewportLayoutController.layoutViewport()
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

  // MARK: - Initialization

  init(fullMessage: FullMessage, props: MessageViewProps) {
    self.fullMessage = fullMessage
    self.props = props
    super.init(frame: .zero)
    addHoverTrackingArea()
    setupScrollStateObserver()
    setupView()
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

    addSubview(timeAndStateView)

    if showsAvatar {
      addSubview(avatarView)
    }

    if showsName {
      addSubview(nameLabel)
      let name = from.firstName ?? from.username ?? ""
      nameLabel.stringValue = outgoing ? "You" : name
      nameLabel.textColor = NSColor(
        InitialsCircle.ColorPalette
          .color(for: name)
      )
    }

    addSubview(contentView)

    if hasPhoto {
      contentView.addArrangedSubview(photoView)
    }

    // TODO: if has text
    contentView.addArrangedSubview(aboveTextSpacer)
    contentView.addArrangedSubview(textView)
    contentView.addArrangedSubview(underTextSpacer)

    setupMessageText()
    setupConstraints()
    setupContextMenu()
  }

  private var textViewWidthConstraint: NSLayoutConstraint!
  private var textViewHeightConstraint: NSLayoutConstraint!
  private var photoViewHeightConstraint: NSLayoutConstraint!
  private var contentViewWidthConstraint: NSLayoutConstraint!

  private func setupConstraints() {
    var topPadding = 0.0
    let nameAndContentGap = Theme.messageVerticalStackSpacing
    let bgPadding = 0.0
    let avatarLeading = Theme.messageSidePadding
    let contentLeading = avatarLeading + Self.avatarSize + Theme.messageHorizontalStackSpacing - bgPadding
    let sidePadding = Theme.messageSidePadding - bgPadding
    let senderNameLeadingPadding = 0.0

    if props.firstInGroup {
      topPadding += Theme.messageGroupSpacing
    }

    if showsAvatar {
      NSLayoutConstraint.activate([
        avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: avatarLeading),
        avatarView.topAnchor.constraint(
          equalTo: topAnchor,
          constant:
          topPadding
        ),
        avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
        avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
      ])
    }

    if showsName {
      NSLayoutConstraint.activate([
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading + senderNameLeadingPadding),
        nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
        nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -sidePadding),
        nameLabel.heightAnchor
          .constraint(equalToConstant: Theme.messageNameLabelHeight),
      ])
    }

    // MARK: - Content Layout Constraints

    contentViewWidthConstraint = contentView.widthAnchor.constraint(equalToConstant: contentWidth)
    textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: props.textHeight ?? 0)

    /// let's not set a height for content stack view and have it use the height from text + photo + gap itself, hmm?
    /// also i won't add width on text view as it must be enforced at content view level at this point. let's try.
    NSLayoutConstraint.activate([
      // Content view
      contentViewWidthConstraint,
      contentView
        .leadingAnchor.constraint(
          equalTo: leadingAnchor,
          constant: contentLeading
        ),
      contentView.topAnchor.constraint(
        equalTo: showsName ? nameLabel.bottomAnchor : topAnchor,
        constant: showsName ? nameAndContentGap : topPadding
      ),

      // Text view
      textViewHeightConstraint,
      // Text view bubble paddings
      textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])

    if hasPhoto, let photoHeight = props.photoHeight {
      photoViewHeightConstraint = photoView.heightAnchor.constraint(equalToConstant: photoHeight)
      NSLayoutConstraint.activate(
        [
          photoViewHeightConstraint,
        ]
      )
    }

    NSLayoutConstraint.activate(
      [
        // Time and state view
        timeAndStateView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding),
        timeAndStateView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ]
    )
  }

  private func setupMessageText() {
    // Setup time and state
    // Show when failed or sending
    setTimeAndStateVisibility(visible: shouldAlwaysShowTimeAndState)

    // Setup text
    let text = message.text ?? ""

    textView.baseWritingDirection = props.isRtl ? .rightToLeft : .natural

    if let attrs = CacheAttrs.shared.get(message: message) {
      textView.textStorage?.setAttributedString(attrs)

//      if let textLayoutManager = textView.textLayoutManager {
//        textLayoutManager
//          .ensureLayout(for: textLayoutManager.documentRange)
//      }

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
//    if let textLayoutManager = textView.textLayoutManager {
//      textLayoutManager
//        .ensureLayout(for: textLayoutManager.documentRange)
//    }

    CacheAttrs.shared.set(message: message, value: attributedString)
  }

  private func setupContextMenu() {
    let menu = NSMenu()

    let idItem = NSMenuItem(title: "ID: \(message.id)", action: nil, keyEquivalent: "")
    idItem.isEnabled = false
    menu.addItem(idItem)

    let indexItem = NSMenuItem(
      title: "Index: \(props.index?.description ?? "?")",
      action: nil,
      keyEquivalent: ""
    )
    indexItem.isEnabled = false
    menu.addItem(indexItem)

    let copyItem = NSMenuItem(title: "Copy", action: #selector(copyMessage), keyEquivalent: "c")
    menu.addItem(copyItem)

    menu.delegate = self
    self.menu = menu
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

  private func updatePropsAndUpdateLayout(props: MessageViewProps) {
    // save for comparison
    let prevProps = self.props

    // update internal props (must update so contentView is recalced)
    self.props = props

    // less granular
    // guard props != self.props else { return }

    let hasTextSizeChanged =
      prevProps.textWidth != props.textWidth ||
      prevProps.textHeight != props.textHeight
    let hasPhotoSizeChanged =
      prevProps.photoWidth != props.photoWidth ||
      prevProps.photoHeight != props.photoHeight

    // only proceed if text size or photo size has changed
    // Fun fact: I wasted too much time on || being &&
    guard hasTextSizeChanged || hasPhotoSizeChanged
    else { return }

    // # Update sizes
    // Content view
    contentViewWidthConstraint.constant = contentWidth

    // Text size
    if hasTextSizeChanged {
      textViewHeightConstraint.constant = props.textHeight ?? 0

      // This helps refresh the layout for textView
      textView.textContainer?.containerSize = CGSize(width: textWidth, height: props.textHeight ?? 0)

      if useTextKit2 {
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        textView.layout()
        textView.display()
      }
    }

    // photo size
    if hasPhotoSizeChanged,
       let photoViewHeightConstraint,
       let photoHeight = props.photoHeight
    {
      photoViewHeightConstraint.constant = photoHeight
    }
  }

  public func updateTextAndSize(fullMessage: FullMessage, props: MessageViewProps) {
    // update internal props
    self.fullMessage = fullMessage

    // update props and reflect changes
    updatePropsAndUpdateLayout(props: props)

    setupMessageText()

    // As the message changes here, we need to update everything related to that. Otherwise we get wrong context menu.
    setupContextMenu()

    // Update time and state
    timeAndStateView.updateMessage(fullMessage)
  }

  public func updateSize(props: MessageViewProps) {
    // update props and reflect changes
    updatePropsAndUpdateLayout(props: props)
  }

  private func setTimeAndStateVisibility(visible: Bool) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = visible ? 0.05 : 0.05
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      context.allowsImplicitAnimation = true
      timeAndStateView.layer?.opacity = visible ? 1 : 0
    }
  }

  // MARK: - Actions

  @objc private func copyMessage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.text ?? "", forType: .string)
  }

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

    if !shouldAlwaysShowTimeAndState {
      setTimeAndStateVisibility(visible: isHovered)
    }
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

struct MessageViewProps: Equatable, Codable, Hashable {
  /// Used to show sender and photo
  var firstInGroup: Bool
  var isLastMessage: Bool
  var isFirstMessage: Bool
  var isRtl: Bool

  var textWidth: CGFloat?
  var textHeight: CGFloat?

  var photoWidth: CGFloat?
  var photoHeight: CGFloat?

  var index: Int?

  /// Used in cache key
  func toString() -> String {
    "\(firstInGroup ? "FG" : "")\(isLastMessage == true ? "LM" : "")\(isFirstMessage == true ? "FM" : "")\(isRtl ? "RTL" : "")"
  }

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

import AppKit
import InlineKit
import Logger

typealias MessageAvatarSwipeProvider = (NSView) -> NSView?

protocol MessageTableRenderableView: AnyObject {
  func updateTextAndSize(fullMessage: FullMessage, props: MessageViewProps, animate: Bool)
  func updateSize(props: MessageViewProps)
  func reflectBoundsChange(fraction: CGFloat)
  func setScrollState(_ state: MessageListScrollState)
  func setListHoverState(_ isHovered: Bool)
  func containsListHoverPoint(_ point: NSPoint, from coordinateView: NSView) -> Bool
  func avatarOverlayItem(in coordinateView: NSView) -> MessageAvatarOverlayItem?
  func setAvatarSwipeProvider(_ provider: MessageAvatarSwipeProvider?)
  func reset()
}

extension MessageTableRenderableView where Self: NSView {
  func setListHoverState(_: Bool) {}

  func containsListHoverPoint(_: NSPoint, from _: NSView) -> Bool {
    false
  }

  func avatarOverlayItem(in coordinateView: NSView) -> MessageAvatarOverlayItem? {
    nil
  }

  func setAvatarSwipeProvider(_: MessageAvatarSwipeProvider?) {}
}

extension MessageViewAppKit: MessageTableRenderableView {}
extension MinimalMessageViewAppKit: MessageTableRenderableView {}

class MessageTableCell: NSView {
  private var messageView: (NSView & MessageTableRenderableView)?
  private var currentContent: (message: FullMessage, props: MessageViewProps)?
  private let log = Log.scoped("MessageTableCell", enableTracing: false)
  private var dependencies: AppDependencies?
  private var avatarSwipeProvider: MessageAvatarSwipeProvider?
  static let forwardSelectionInset: CGFloat = 22
  private var forwardSelectionCheckmark: ForwardMessageSelectionCheckmark?
  private var messageTrailingConstraint: NSLayoutConstraint?
  private var forwardSelectionActive = false

  func setForwardSelection(active: Bool, selectable: Bool, selected: Bool, onToggle: @escaping () -> Void) {
    forwardSelectionActive = active
    messageTrailingConstraint?.constant = active ? -Self.forwardSelectionInset : 0
    if active, selectable {
      if forwardSelectionCheckmark == nil {
        let checkmark = ForwardMessageSelectionCheckmark()
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkmark)
        NSLayoutConstraint.activate([
          checkmark.widthAnchor.constraint(equalToConstant: 22),
          checkmark.heightAnchor.constraint(equalToConstant: 22),
          checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
          checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        forwardSelectionCheckmark = checkmark
      }
      forwardSelectionCheckmark?.state = selected ? .on : .off
      forwardSelectionCheckmark?.onToggle = onToggle
      forwardSelectionCheckmark?.needsDisplay = true
      forwardSelectionCheckmark?.isHidden = false
    } else {
      forwardSelectionCheckmark?.isHidden = true
      forwardSelectionCheckmark?.onToggle = nil
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    MessageGestureTrace.trace("MessageTableCell.hitTest messageId=\(currentContent?.message.message.messageId ?? 0) parentPoint=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(convert(point, from: superview))) cell=\(MessageGestureTrace.view(self)) rendered=\(MessageGestureTrace.view(messageView)) hit=\(MessageGestureTrace.view(hit))")
    return hit
  }

  override func mouseDown(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.mouseDown messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.mouseUp messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.mouseUp(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.mouseDragged messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.mouseDragged(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.rightMouseDown messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.rightMouseDown(with: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.rightMouseUp messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.rightMouseUp(with: event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.rightMouseDragged messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.rightMouseDragged(with: event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.otherMouseDragged messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.otherMouseDragged(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.otherMouseDown messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTableCell.otherMouseUp messageId=\(currentContent?.message.message.messageId ?? 0) \(MessageGestureTrace.eventDescription(event))")
    super.otherMouseUp(with: event)
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = .clear
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  private var wasTranslated: Bool? = nil

  func setDependencies(_ dependencies: AppDependencies) {
    self.dependencies = dependencies
    (messageView as? ServiceMessageViewAppKit)?.setDependencies(dependencies)
  }

  func setAvatarSwipeProvider(_ provider: MessageAvatarSwipeProvider?) {
    avatarSwipeProvider = provider
    messageView?.setAvatarSwipeProvider(provider)
  }

  func configure(with message: FullMessage, props: MessageViewProps, animate: Bool = true) {
    defer { wasTranslated = message.isTranslated }

    if message == currentContent?.message,
       props == currentContent?.props,
       // And same translation
       wasTranslated == message.isTranslated
    {
      // layoutSubtreeIfNeeded()
      // added this to solve the clipping issue in scroll view on last message when it was multiline and initial height
      // was calculated with a wider width during the table view setup
      // Update: commented when I was debugging slow message sending
      return
    }

    // ONLY SIZE CHANGE
    if let currentContent,
       // has view
       messageView != nil,
       // same message
       currentContent.message == message,
       // and translate not changed
       wasTranslated == message.isTranslated,
       // different width and height (ie. window resized)
       currentContent.props.equalExceptSize(props),
       currentContent.props.layout.hasSameRichBlockTopology(as: props.layout),
       currentContent.props.layout.hasSameConstraintTopology(as: props.layout)
    {
      self.currentContent = (message, props)
      log.trace("updating message size \(currentContent.message.message.id ?? 0)")
      updateSize()
      return
    }

    // RE-USE
    if let currentContent,
       // has view
       messageView != nil,
       // same sender
       currentContent.message.message.fromId == message.message.fromId,
       // same message layout
       currentContent.message.message.out == message.message.out,
       currentContent.message.message.isServiceMessage == message.message.isServiceMessage,
       currentContent.message.message.repliedToMessageId == message.message.repliedToMessageId,
       currentContent.message.message.hasForwardHeader == message.message.hasForwardHeader,
       // exclude file/photo/video from reuse
       currentContent.message.file?.id == message.file?.id,
       currentContent.message.photoInfo?.id == message.photoInfo?.id,
       currentContent.message.videoInfo?.id == message.videoInfo?.id,
       currentContent.message.documentInfo?.id == message.documentInfo?.id,
       // exclude reactions from reuse
       currentContent.message.reactions == message.reactions || currentContent.message.id == message.id,
       // exclude replies from reuse
       currentContent.message.repliedToMessage?.id == message.repliedToMessage?.id,
       // disable re-use for file message completely for now until we can optimize later
       // same message-level layout flags and same constraint graph
       currentContent.props.equalExceptSize(props),
       currentContent.props.layout.hasSameConstraintShape(as: props.layout)
    // For now, recreate if moving from single line to multi line
    // , currentContent.props.layout.isSingleLine == props.layout.isSingleLine
    // different text
    // currentContent.message.message.text != message.message.text
    {
      #if DEBUG
      log.trace("updating message text and size")
      log.trace("transforming cell from \(currentContent.message.message.id) to \(message.message.id)")
      #endif
      self.currentContent = (message, props)
      // Only animate if same message
      let animateForReal = animate && currentContent.message.message.id == message.message.id
      updateTextAndSize(animate: animateForReal)

      return
    }

    // Too expensive.
//    log.trace("""
//    recreating message view for \(message.message.id)
//
//    previous: \(currentContent?.message.debugDescription ?? "nil")
//    new: \(message.debugDescription)
//    """)

    currentContent = (message, props)
    updateContent()
  }

  func updateTextAndSize(animate: Bool = true) {
    guard let content = currentContent else { return }
    guard let messageView else { return }

    messageView.updateTextAndSize(fullMessage: content.0, props: content.1, animate: animate)
    needsDisplay = true
  }

  func updateSizeWithProps(props: MessageViewProps) {
    guard let messageView else { return }
    currentContent?.props = props
    messageView.updateSize(props: props)
    needsDisplay = true
  }

  func updateSize() {
    guard let content = currentContent else { return }
    guard let messageView else { return }

    messageView.updateSize(props: content.1)
    needsDisplay = true
  }

  private func updateContent() {
    guard let content = currentContent else { return }
    // Update subviews with new content

    messageView?.removeFromSuperview()

    let newMessageView: (NSView & MessageTableRenderableView)
    switch (content.0.message.isServiceMessage, content.1.renderStyle) {
    case (true, _):
      newMessageView = ServiceMessageViewAppKit(fullMessage: content.0, dependencies: dependencies)
    case (false, .bubble):
      newMessageView = MessageViewAppKit(
        fullMessage: content.0,
        props: content.1,
        dependencies: dependencies,
        isScrolling: scrollState.isScrolling
      )
    case (false, .minimal):
      newMessageView = MinimalMessageViewAppKit(
        fullMessage: content.0,
        props: content.1,
        dependencies: dependencies,
        isScrolling: scrollState.isScrolling
      )
    }

    newMessageView.setAvatarSwipeProvider(avatarSwipeProvider)

    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(newMessageView)

    let trailing = newMessageView.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: forwardSelectionActive ? -Self.forwardSelectionInset : 0
    )
    messageTrailingConstraint = trailing
    NSLayoutConstraint.activate([
      newMessageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      trailing,
      newMessageView.topAnchor.constraint(equalTo: topAnchor),
      newMessageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    messageView = newMessageView
    needsDisplay = true
  }

  func reflectBoundsChange(fraction: CGFloat) {
    messageView?.reflectBoundsChange(fraction: fraction)
  }

  func avatarOverlayItem(in coordinateView: NSView) -> MessageAvatarOverlayItem? {
    messageView?.avatarOverlayItem(in: coordinateView)
  }

  func setMessageHoverState(_ isHovered: Bool) {
    messageView?.setListHoverState(isHovered)
  }

  var quickActionsMessageView: MinimalMessageViewAppKit? {
    messageView as? MinimalMessageViewAppKit
  }

  func containsMessageHoverPoint(_ point: NSPoint, from coordinateView: NSView) -> Bool {
    messageView?.containsListHoverPoint(point, from: coordinateView) ?? false
  }

  private var scrollState: MessageListScrollState = .idle
  func setScrollState(_ state: MessageListScrollState) {
    scrollState = state
    messageView?.setScrollState(state)
  }

  func highlight() {
    let currentMsgId = currentContent?.message.message.messageId

    // Create animation
    let fadeIn = CABasicAnimation(keyPath: "backgroundColor")
    fadeIn.fromValue = NSColor.clear.cgColor
    fadeIn.toValue = NSColor.systemGray.withAlphaComponent(0.2).cgColor
    fadeIn.duration = 0.2
    fadeIn.fillMode = .forwards
    fadeIn.isRemovedOnCompletion = false

    // Apply animation
    layer?.add(fadeIn, forKey: "fadeInAnimation")

    // Schedule fade out animation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      if self.currentContent?.message.message.messageId != currentMsgId {
        // cell was reused
        return
      }

      let fadeOut = CABasicAnimation(keyPath: "backgroundColor")
      fadeOut.fromValue = NSColor.systemGray.withAlphaComponent(0.2).cgColor
      fadeOut.toValue = NSColor.clear.cgColor
      fadeOut.duration = 0.25
      fadeOut.fillMode = .forwards
      fadeOut.isRemovedOnCompletion = false

      self.layer?.add(fadeOut, forKey: "fadeOutAnimation")

      // Clean up after animation completes
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.layer?.removeAllAnimations()
      }
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    layer?.removeAllAnimations()
    wasTranslated = nil
    messageView?.reset()
    forwardSelectionCheckmark?.isHidden = true
    forwardSelectionCheckmark?.onToggle = nil
  }
}

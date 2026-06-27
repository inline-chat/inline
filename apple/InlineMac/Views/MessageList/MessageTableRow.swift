import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI
import Translation

private protocol MessageTableRenderableView: AnyObject {
  func updateTextAndSize(fullMessage: FullMessage, props: MessageViewProps, animate: Bool)
  func updateSize(props: MessageViewProps)
  func reflectBoundsChange(fraction: CGFloat)
  func setScrollState(_ state: MessageListScrollState)
  func avatarOverlayItem(in coordinateView: NSView) -> MessageAvatarOverlayItem?
  func reset()
}

private extension MessageTableRenderableView where Self: NSView {
  func avatarOverlayItem(in coordinateView: NSView) -> MessageAvatarOverlayItem? {
    nil
  }
}

extension MessageViewAppKit: MessageTableRenderableView {}
extension MinimalMessageViewAppKit: MessageTableRenderableView {}

private final class ServiceMessageViewAppKit: NSView, MessageTableRenderableView {
  private let containerView = NSView()
  private let stackView = NSStackView()
  private var fullMessage: FullMessage
  private var dependencies: AppDependencies?

  init(fullMessage: FullMessage, dependencies: AppDependencies?) {
    self.fullMessage = fullMessage
    self.dependencies = dependencies
    super.init(frame: .zero)
    setupView()
    updateText()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  func setDependencies(_ dependencies: AppDependencies) {
    self.dependencies = dependencies
  }

  func updateTextAndSize(fullMessage: FullMessage, props _: MessageViewProps, animate _: Bool) {
    self.fullMessage = fullMessage
    updateText()
  }

  func updateSize(props _: MessageViewProps) {}

  func reflectBoundsChange(fraction _: CGFloat) {}

  func setScrollState(_: MessageListScrollState) {}

  func reset() {}

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = .clear

    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.wantsLayer = true
    containerView.layer?.cornerRadius = 11
    containerView.layer?.masksToBounds = true
    addSubview(containerView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.orientation = .horizontal
    stackView.alignment = .firstBaseline
    stackView.spacing = 0
    stackView.distribution = .fill
    containerView.addSubview(stackView)

    NSLayoutConstraint.activate([
      containerView.centerXAnchor.constraint(equalTo: centerXAnchor),
      containerView.centerYAnchor.constraint(equalTo: centerYAnchor),
      containerView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),

      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 5),
      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
      stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -5),
    ])

    updateAppearance()
  }

  private func updateText() {
    stackView.arrangedSubviews.forEach { view in
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    for segment in serviceSegments() {
      stackView.addArrangedSubview(view(for: segment))
    }
  }

  private func updateAppearance() {
    containerView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.75).cgColor
  }

  private func serviceSegments() -> [MessageServiceDisplaySegment] {
    fullMessage.serviceDisplaySegments ?? [
      MessageServiceDisplaySegment(text: fullMessage.message.serviceFallbackText
        ?? fullMessage.message.text
        ?? fullMessage.message.stringRepresentationPlain),
    ]
  }

  private func view(for segment: MessageServiceDisplaySegment) -> NSView {
    guard let link = segment.link else {
      return plainLabel(segment.text, tone: segment.tone)
    }

    return ServiceMessageLinkLabel(
      text: segment.text,
      link: link,
      tone: segment.tone,
      onOpen: { [weak self] link in
        self?.open(link)
      }
    )
  }

  private func plainLabel(_ text: String, tone: MessageServiceDisplaySegment.Tone) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Self.font
    label.textColor = Self.textColor(for: tone)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }

  private func open(_ link: MessageServiceDisplaySegment.Link) {
    switch link {
      case let .user(userId):
        dependencies?.requestOpenChat(peer: .user(id: userId))
      case let .thread(chatId):
        dependencies?.requestOpenChat(peer: .thread(id: chatId))
    }
  }

  fileprivate static func textColor(for tone: MessageServiceDisplaySegment.Tone) -> NSColor {
    switch tone {
      case .secondary:
        return .secondaryLabelColor
      case .tertiary:
        return .tertiaryLabelColor
    }
  }

  fileprivate static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
}

private final class ServiceMessageLinkLabel: NSTextField {
  private let link: MessageServiceDisplaySegment.Link
  private let onOpen: (MessageServiceDisplaySegment.Link) -> Void

  init(
    text: String,
    link: MessageServiceDisplaySegment.Link,
    tone: MessageServiceDisplaySegment.Tone,
    onOpen: @escaping (MessageServiceDisplaySegment.Link) -> Void
  ) {
    self.link = link
    self.onOpen = onOpen
    super.init(frame: .zero)

    isBezeled = false
    isBordered = false
    isEditable = false
    isSelectable = false
    drawsBackground = false
    font = ServiceMessageViewAppKit.font
    lineBreakMode = .byTruncatingTail
    maximumNumberOfLines = 1
    attributedStringValue = NSAttributedString(
      string: text,
      attributes: [
        .font: ServiceMessageViewAppKit.font,
        .foregroundColor: ServiceMessageViewAppKit.textColor(for: tone),
      ]
    )
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .vertical)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func mouseDown(with event: NSEvent) {
    onOpen(link)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

class MessageTableCell: NSView {
  private var messageView: (NSView & MessageTableRenderableView)?
  private var currentContent: (message: FullMessage, props: MessageViewProps)?
  private let log = Log.scoped("MessageTableCell", enableTracing: false)
  private var dependencies: AppDependencies?

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
       currentContent.props.layout.hasSameConstraintShape(as: props.layout)
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

    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(newMessageView)

    NSLayoutConstraint.activate([
      newMessageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      newMessageView.trailingAnchor.constraint(equalTo: trailingAnchor),
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
  }
}

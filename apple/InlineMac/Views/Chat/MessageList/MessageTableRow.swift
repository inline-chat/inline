import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI

class MessageTableCell: NSView {
  private var messageView: MessageViewAppKit?
  private var currentContent: (message: FullMessage, props: MessageViewProps)?
  private let log = Log.scoped("MessageTableCell", enableTracing: false)

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
       currentContent.props.equalExceptSize(props)
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
       currentContent.message.message.repliedToMessageId == message.message.repliedToMessageId,
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
       // same avatar
       currentContent.props.firstInGroup == props.firstInGroup
    // For now, recreate if moving from single line to multi line
    // , currentContent.props.layout.isSingleLine == props.layout.isSingleLine
    // different text
    // currentContent.message.message.text != message.message.text
    {
      log.trace("updating message text and size")
      #if DEBUG
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

    let newMessageView = MessageViewAppKit(
      fullMessage: content.0,
      props: content.1,
      isScrolling: scrollState.isScrolling
    )
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

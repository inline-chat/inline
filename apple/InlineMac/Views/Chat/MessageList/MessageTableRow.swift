import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI

class MessageTableCell: NSView {
  private var messageView: MessageViewAppKit?
  private var currentContent: (message: FullMessage, props: MessageViewProps)?
  private let log = Log.scoped("MessageTableCell", enableTracing: true)

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
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  func configure(with message: FullMessage, props: MessageViewProps) {
    if message == currentContent?.message, props == currentContent?.props {
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
       // different width and height (ie. window resized)
       currentContent.props.equalExceptSize(props)
    {
      log.trace("updating message size")
      self.currentContent = (message, props)
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
       // exclude replies from reuse
       currentContent.message.repliedToMessage?.id == message.repliedToMessage?.id,
       // disable re-use for file message completely for now until we can optimize later
       // same avatar
       currentContent.props.firstInGroup == props.firstInGroup
    // different text
    // currentContent.message.message.text != message.message.text
    {
      log.trace("updating message text and size")
      log.trace("transforming cell from \(currentContent.message.message.id) to \(message.message.id)")
      self.currentContent = (message, props)
      updateTextAndSize()

      return
    }

    log.trace("""
    recreating message view for \(message.message.id)

    previous: \(currentContent?.message.debugDescription ?? "nil")
    new: \(message.debugDescription)
    """)

    currentContent = (message, props)
    updateContent()
  }

//  func ensureLayout(_ props: MessageViewProps) {
//    messageView?.ensureLayout(props)
//    layoutSubtreeIfNeeded()
//  }

  func updateTextAndSize() {
    guard let content = currentContent else { return }
    guard let messageView else { return }

    messageView.updateTextAndSize(fullMessage: content.0, props: content.1)
    needsDisplay = true
  }

  func updateTextAndSizeWithProps(props: MessageViewProps) {
    guard let content = currentContent else { return }
    guard let messageView else { return }

    messageView.updateTextAndSize(fullMessage: content.0, props: props)
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

    let newMessageView = MessageViewAppKit(fullMessage: content.0, props: content.1)
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

  override func prepareForReuse() {
    super.prepareForReuse()
  }
}

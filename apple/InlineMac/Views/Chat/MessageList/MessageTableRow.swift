import AppKit
import InlineKit
import InlineUI
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
    if message == currentContent?.message && props == currentContent?.props {
      // layoutSubtreeIfNeeded()
      // added this to solve the clipping issue in scroll view on last message when it was multiline and initial height was calculated with a wider width during the table view setup
      // Update: commented when I was debugging slow message sending
      return
    }
    
    // ONLY SIZE CHANGE
    if let currentContent = currentContent,
       // has view
       messageView != nil,
       // same message
       currentContent.message == message,
       // different width and height (ie. window resized)
       currentContent.props.equalExceptSize(props)
    {
      log.debug("updating message size")
      self.currentContent = (message, props)
      updateSize()
      return
    }
    
    // RE-USE
    if let currentContent = currentContent,
       // has view
       messageView != nil,
       // same sender
       currentContent.message.message.fromId == message.message.fromId,
       // same message layout
       currentContent.message.message.out == message.message.out,
       currentContent.message.message.repliedToMessageId == message.message.repliedToMessageId,
       // exclude file/photo/video
       currentContent.message.file == message.file, // disable re-use for file message completely for now until we can optimize later
       // same avatar
       currentContent.props.firstInGroup == props.firstInGroup
    // different text
    // currentContent.message.message.text != message.message.text
    {
      log.debug("updating message text and size")
      log.debug("transforming cell from \(currentContent.message.message.id) to \(message.message.id)")
      self.currentContent = (message, props)
      updateTextAndSize()
      return
    }
    
    log.debug("recreating message view")
      
    // TODO: Don't recreate on width/height change
//    if let prevProps = currentContent?.props,
//       message == currentContent?.message &&
//       props.equalExceptSize(prevProps)
//    {
//      currentContent = (message, props)
//      ensureLayout(props)
//      return
//    }
    
    currentContent = (message, props)
    updateContent()
  }

//  func ensureLayout(_ props: MessageViewProps) {
//    messageView?.ensureLayout(props)
//    layoutSubtreeIfNeeded()
//  }
  
  func updateTextAndSize() {
    guard let content = currentContent else { return }
    guard let messageView = messageView else { return }
    
    messageView.updateTextAndSize(fullMessage: content.0, props: content.1)
    needsDisplay = true
  }
  
  func updateSize() {
    guard let content = currentContent else { return }
    guard let messageView = messageView else { return }
    
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
      
      // Apply inter message paddings
      newMessageView.topAnchor.constraint(equalTo: topAnchor, constant: Theme.messageOuterVerticalPadding),
      newMessageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.messageOuterVerticalPadding)
    ])
    
    messageView = newMessageView
    needsDisplay = true
  }

  override func prepareForReuse() {
    super.prepareForReuse()
  }
}

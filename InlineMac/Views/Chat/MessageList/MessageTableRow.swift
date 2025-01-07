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
  
  private func setupView() {}
  
  func configure(with message: FullMessage, props: MessageViewProps) {
    if message == currentContent?.message && props == currentContent?.props {
      // layoutSubtreeIfNeeded()
      // added this to solve the clipping issue in scroll view on last message when it was multiline and initial height was calculated with a wider width during the table view setup
      // Update: commented when I was debugging slow message sending
      return
    }
    
    log.debug("recreating message view")
      
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
      newMessageView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    
    messageView = newMessageView
  }

  override func prepareForReuse() {
    super.prepareForReuse()
  }
}

import AppKit
import InlineKit
import InlineUI
import SwiftUI

class MessageTableCell: NSTableCellView {
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
//    wantsLayer = true
//    layer?.backgroundColor = .clear
  }
  
  private func onlyContentNeedsChange(_ message: FullMessage, _ props: MessageViewProps) -> Bool {
    guard let currentContent = currentContent else { return false }
    let aM = currentContent.message.message
    let bM = message.message
    let aP = currentContent.props
    let bP = props
    
    return aM.status == bM.status &&
      aM.fromId == bM.fromId &&
      aP.firstInGroup == bP.firstInGroup &&
      aP.isFirstMessage == bP.isFirstMessage &&
      aP.isLastMessage == bP.isLastMessage &&
      aP.isRtl == bP.isRtl &&
      // NOT EQUAL CONTENT
      aM.text != bM.text
  }
  
  func configure(with fullMessage: FullMessage, props: MessageViewProps) {
    if onlyContentNeedsChange(fullMessage, props) {
      log.trace("configuring only inner content \(fullMessage.id) \(props.toString())")
      currentContent = (fullMessage, props)
      updateInnerContent()
    } else if currentContent?.message != fullMessage ||
      currentContent?.props.equalContentTo(props) == false
    {
      // Update if content has changed
      log.trace("configuring with new content \(fullMessage.id) \(props.toString())")
      currentContent = (fullMessage, props)
      updateContent()
    } else if currentContent?.props.width != props.width || currentContent?.props.height != props.height {
      log.trace("configuring with new sizes")
      // Content equal but width / height changed
      currentContent = (fullMessage, props)
      updateSizes()
    }
    
    // Equal
  }
  
  private func updateSizes() {
    messageView?.updateSizes(props: currentContent!.1)
  }
  
  private func updateInnerContent() {
    messageView?.updateInnerContent(fullMessage: currentContent!.0, props: currentContent!.1)
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
      newMessageView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    
    messageView = newMessageView
    
    // Force layout update
//    layoutSubtreeIfNeeded()
  }

//  override func prepareForReuse() {
//    super.prepareForReuse()
//    log.trace("prepareForReuse")
//    currentContent = nil
//    // Clear any other state
//  }
}

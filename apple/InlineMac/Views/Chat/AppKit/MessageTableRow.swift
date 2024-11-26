import AppKit
import InlineKit
import InlineUI
import SwiftUI

class MessageTableCell: NSTableCellView {
  private var messageView: MessageViewAppKit?
  private var currentContent: (message: FullMessage, props: MessageViewProps)?
  
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
  }
  
  func configure(with fullMessage: FullMessage, props: MessageViewProps) {
    // Skip update if content hasn't changed
//    guard currentContent?.message != fullMessage ||
//      currentContent?.props != props else { return }

    currentContent = (fullMessage, props)
    
    updateContent()
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
    layoutSubtreeIfNeeded()
  }
  private func updateContent(message: FullMessage, props: MessageViewProps) {
    // Your existing view update logic
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    currentContent = nil
    // Clear any other state
  }
//  // Add prepareForReuse to reset state if needed
//  override func prepareForReuse() {
//    // Reset any temporary state
//    super.prepareForReuse()
//  }
}

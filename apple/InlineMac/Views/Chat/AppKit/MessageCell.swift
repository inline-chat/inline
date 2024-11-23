// MessageCellView.swift
import AppKit
import InlineKit
import SwiftUI

class MessageCell: NSCollectionViewItem {
  static let reuseIdentifier = "MessageCell"
  
  private var messageView: MessageViewAppKit?
  
  override func loadView() {
    view = NSView()
  }
  
  func configure(with fullMessage: FullMessage, showsSender: Bool) {
    messageView?.removeFromSuperview()
    
    let newMessageView = MessageViewAppKit(fullMessage: fullMessage, showsSender: showsSender)
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(newMessageView)
    
    NSLayoutConstraint.activate([
      newMessageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      newMessageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      newMessageView.topAnchor.constraint(equalTo: view.topAnchor),
      newMessageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    
    messageView = newMessageView
  }
}

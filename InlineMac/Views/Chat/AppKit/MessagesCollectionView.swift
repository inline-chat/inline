// MessagesCollectionView.swift
import AppKit
import InlineKit
import SwiftUI

struct MessagesCollectionView: NSViewControllerRepresentable {
  @EnvironmentObject private var messageStore: FullChatViewModel
  var onCopy: ((String) -> Void)? = nil
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  func makeNSViewController(context: Context) -> MessagesViewController {
    let controller = MessagesViewController()
    controller.delegate = context.coordinator
    controller.update(with: messageStore.fullMessages)
    return controller
  }
  
  func updateNSViewController(_ nsViewController: MessagesViewController, context: Context) {
    nsViewController.update(with: messageStore.fullMessages)
    context.coordinator.parent = self
  }
  
  class Coordinator: NSObject, MessagesViewControllerDelegate {
    var parent: MessagesCollectionView
    
    init(_ parent: MessagesCollectionView) {
      self.parent = parent
    }
    
    func messagesViewController(_ controller: MessagesViewController, didSelectMessages selectedIds: Set<UUID>) {
      // Handle selection if needed
    }
    
    func messagesViewController(_ controller: MessagesViewController, didCopyText text: String) {
      parent.onCopy?(text)
    }
  }
}

extension MessagesCollectionView: Equatable {
  static func == (lhs: MessagesCollectionView, rhs: MessagesCollectionView) -> Bool {
    true // Since we're using EnvironmentObject, we don't need to compare
  }
}

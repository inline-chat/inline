// MessagesCollectionView.swift
import AppKit
import InlineKit
import SwiftUI

struct MessagesList: NSViewControllerRepresentable {
  @EnvironmentObject private var messageStore: FullChatViewModel
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  func makeNSViewController(context: Context) -> MessageListAppKit {
    let controller = MessageListAppKit()
    controller.update(with: messageStore.fullMessages)
    return controller
  }
  
  func updateNSViewController(_ nsViewController: MessageListAppKit, context: Context) {
    nsViewController.update(with: messageStore.fullMessages)
    context.coordinator.parent = self
  }
  
  class Coordinator: NSObject {
    var parent: MessagesList
    
    init(_ parent: MessagesList) {
      self.parent = parent
    }
  }
}

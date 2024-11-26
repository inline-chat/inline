// MessagesCollectionView.swift
import AppKit
import InlineKit
import SwiftUI

struct MessagesList: NSViewControllerRepresentable {
  @EnvironmentObject private var messageStore: FullChatViewModel
  var width: CGFloat
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  func makeNSViewController(context: Context) -> MessagesTableView {
    print("MessageList init width \(width)")
    let controller = MessagesTableView(width: width)
    controller.update(with: messageStore.fullMessages, width: width)
    return controller
  }
  
  func updateNSViewController(_ nsViewController: MessagesTableView, context: Context) {
    print("update called")
    nsViewController.update(with: messageStore.fullMessages, width: width)
    context.coordinator.parent = self
  }
  
  class Coordinator: NSObject {
    var parent: MessagesList
    
    init(_ parent: MessagesList) {
      self.parent = parent
    }
  }
}

//struct MessagesList: NSViewControllerRepresentable {
//  @EnvironmentObject private var messageStore: FullChatViewModel
//  
//  func makeCoordinator() -> Coordinator {
//    Coordinator(self)
//  }
//  
//  func makeNSViewController(context: Context) -> MessagesViewController {
//    let controller = MessagesViewController()
//    controller.update(with: messageStore.fullMessages.reversed())
//    return controller
//  }
//  
//  func updateNSViewController(_ nsViewController: MessagesViewController, context: Context) {
//    nsViewController.update(with: messageStore.fullMessages)
//    context.coordinator.parent = self
//  }
//  
//  class Coordinator: NSObject {
//    var parent: MessagesList
//    
//    init(_ parent: MessagesList) {
//      self.parent = parent
//    }
//  }
//}


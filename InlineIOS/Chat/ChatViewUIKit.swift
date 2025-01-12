import InlineKit
import SwiftUI
import UIKit

class ChatContainerView: UIView {
  private let peerId: Peer
    
  private lazy var messagesCollectionView: MessagesCollectionView2 = {
    let collectionView = MessagesCollectionView2(peerId: peerId)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    return collectionView
  }()
    
  private lazy var composeView: ComposeView2 = {
    let view = ComposeView2()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onHeightChange = { [weak self] newHeight in
      self?.handleComposeViewHeightChange(newHeight)
    }
    view.onSend = { [weak self] _ in
      // TODO: Handle send message
    }
    return view
  }()
    
  init(peerId: Peer) {
    self.peerId = peerId
    super.init(frame: .zero)
    setupViews()
//    setupKeyboardObservers()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  private func setupViews() {
    backgroundColor = .systemBackground
        
    addSubview(messagesCollectionView)
    addSubview(composeView)
        
    // Enable keyboard layout guide tracking
    keyboardLayoutGuide.followsUndockedKeyboard = true

    NSLayoutConstraint.activate([
      messagesCollectionView.topAnchor.constraint(equalTo: topAnchor),
//      messagesCollectionView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      messagesCollectionView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      messagesCollectionView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
//      messagesCollectionView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
      messagesCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
      
      composeView.leadingAnchor.constraint(equalTo: leadingAnchor),
      composeView.trailingAnchor.constraint(equalTo: trailingAnchor),
      composeView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
    ])
  }
    
//  private func setupKeyboardObservers() {
//    NotificationCenter.default.addObserver(
//      self,
//      selector: #selector(keyboardWillShow),
//      name: UIResponder.keyboardWillShowNotification,
//      object: nil
//    )
//
////    NotificationCenter.default.addObserver(
////      self,
////      selector: #selector(keyboardWillHide),
////      name: UIResponder.keyboardWillHideNotification,
////      object: nil
////    )
//  }

//
//  @objc private func keyboardWillShow(_ notification: Notification) {
//    guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
//          let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
//    else {
//      return
//    }
//
//    let keyboardHeight = keyboardFrame.height
//    composeViewBottomConstraint.constant = -keyboardHeight
//
//    UIView.animate(withDuration: duration) {
//      self.layoutIfNeeded()
//    }
//  }
//
//  @objc private func keyboardWillHide(_ notification: Notification) {
//    guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
//      return
//    }
//
//    composeViewBottomConstraint.constant = 0
//
//    UIView.animate(withDuration: duration) {
//      self.layoutIfNeeded()
//    }
//  }
    
  private func handleComposeViewHeightChange(_ newHeight: CGFloat) {
    messagesCollectionView.updateComposeInset(composeHeight: newHeight)
    
    layoutIfNeeded()
  }
}

struct ChatViewUIKit: UIViewRepresentable {
  let peerId: Peer
    
  func makeUIView(context: Context) -> ChatContainerView {
    return ChatContainerView(peerId: peerId)
  }
    
  func updateUIView(_ uiView: ChatContainerView, context: Context) {}
}

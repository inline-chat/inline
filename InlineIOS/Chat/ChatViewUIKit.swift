import InlineKit
import SwiftUI
import UIKit

class ChatContainerView: UIView {
  private let peerId: Peer
  var onSend: ((String) -> Void)?

  private lazy var messagesCollectionView: MessagesCollectionView = {
    let collectionView = MessagesCollectionView(peerId: peerId)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    return collectionView
  }()
    
  private lazy var composeView: ComposeView = {
    let view = ComposeView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onHeightChange = { [weak self] newHeight in
      self?.handleComposeViewHeightChange(newHeight)
    }
    view.peerId = peerId
    view.onSend = onSend
    return view
  }()
    
  init(peerId: Peer, _ onSend: @escaping (String) -> Void) {
    self.peerId = peerId
    self.onSend = onSend
    super.init(frame: .zero)
    setupViews()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  private func setupViews() {
    backgroundColor = .systemBackground
        
    let blurEffect = UIBlurEffect(style: .systemMaterial)
    let blurView = UIVisualEffectView(effect: blurEffect)
    blurView.backgroundColor = .white.withAlphaComponent(0.2)
    blurView.translatesAutoresizingMaskIntoConstraints = false
    
    addSubview(messagesCollectionView)
    addSubview(blurView)
    addSubview(composeView)
    
    // FIXME: probably communicate current height of compose to collectionView
        
    keyboardLayoutGuide.followsUndockedKeyboard = true

    NSLayoutConstraint.activate([
      messagesCollectionView.topAnchor.constraint(equalTo: topAnchor),
      messagesCollectionView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      messagesCollectionView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      messagesCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
      
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.topAnchor.constraint(equalTo: composeView.topAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

      composeView.leadingAnchor.constraint(equalTo: leadingAnchor),
      composeView.trailingAnchor.constraint(equalTo: trailingAnchor),
      composeView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
    ])
  }
    
  private func handleComposeViewHeightChange(_ newHeight: CGFloat) {
    messagesCollectionView.updateComposeInset(composeHeight: newHeight)
    
    layoutIfNeeded()
  }
}

struct ChatViewUIKit: UIViewRepresentable {
  let peerId: Peer
  @EnvironmentObject var fullChatViewModel: FullChatViewModel

  func makeUIView(context: Context) -> ChatContainerView {
    return ChatContainerView(peerId: peerId) { text in
      let _ = fullChatViewModel.sendMessage(text: text)
    }
  }
    
  func updateUIView(_ uiView: ChatContainerView, context: Context) {}
}

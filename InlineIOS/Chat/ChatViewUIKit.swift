import InlineKit
import SwiftUI
import UIKit

class ChatContainerView: UIView {
  let peerId: Peer

  var onSend: ((String) -> Bool)?

  private lazy var messagesCollectionView: MessagesCollectionView = {
    let collectionView = MessagesCollectionView(peerId: peerId)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    return collectionView
  }()

  lazy var composeView: ComposeView = {
    let view = ComposeView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onHeightChange = { [weak self] newHeight in
      self?.handleComposeViewHeightChange(newHeight)
    }
    view.peerId = peerId
    view.onSend = onSend

    return view
  }()

  private lazy var blurView: UIVisualEffectView = {
    let blurEffect = UIBlurEffect(style: .systemMaterial)
    let view = UIVisualEffectView(effect: blurEffect)
    view.backgroundColor = .clear
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var blurViewBottomConstraint: NSLayoutConstraint?

  init(peerId: Peer, _ onSend: @escaping (String) -> Bool) {
    self.peerId = peerId
    self.onSend = onSend
    super.init(frame: .zero)
    setupViews()
    setupKeyboardObservers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    backgroundColor = .systemBackground

    addSubview(messagesCollectionView)
    addSubview(blurView)
    addSubview(composeView)

    // Store the bottom constraint so we can modify it later
    blurViewBottomConstraint = blurView.bottomAnchor.constraint(equalTo: bottomAnchor)

    keyboardLayoutGuide.followsUndockedKeyboard = true

    NSLayoutConstraint.activate([
      messagesCollectionView.topAnchor.constraint(equalTo: topAnchor),
      messagesCollectionView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      messagesCollectionView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      messagesCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.topAnchor.constraint(equalTo: composeView.topAnchor, constant: -ComposeView.textViewVerticalMargin),
      blurViewBottomConstraint!,

      composeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ComposeView.textViewHorizantalMargin),
      composeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ComposeView.textViewHorizantalMargin),
      composeView.bottomAnchor.constraint(
        equalTo: keyboardLayoutGuide.topAnchor, constant: -ComposeView.textViewVerticalMargin
      ),
    ])
  }

  private func setupKeyboardObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillShow),
      name: UIResponder.keyboardWillShowNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillHide),
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
  }

  @objc private func keyboardWillShow(_ notification: Notification) {
    guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
      let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
    else {
      return
    }

    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: .curveEaseOut
    ) {
      self.blurViewBottomConstraint?.isActive = false
      self.blurViewBottomConstraint = self.blurView.bottomAnchor.constraint(equalTo: self.keyboardLayoutGuide.topAnchor)
      self.blurViewBottomConstraint?.isActive = true
      self.layoutIfNeeded()
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
    else {
      return
    }
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: .curveEaseIn
    ) {
      self.blurViewBottomConstraint?.isActive = false
      self.blurViewBottomConstraint = self.blurView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
      self.blurViewBottomConstraint?.isActive = true
      self.layoutIfNeeded()
    }
  }

  private func handleComposeViewHeightChange(_ newHeight: CGFloat) {
    messagesCollectionView.updateComposeInset(composeHeight: newHeight)

    layoutIfNeeded()
  }
}

struct ChatViewUIKit: UIViewRepresentable {
  let peerId: Peer
  @EnvironmentObject var fullChatViewModel: FullChatViewModel
  @EnvironmentObject var data: DataManager

  func makeUIView(context: Context) -> ChatContainerView {
    return ChatContainerView(peerId: peerId) { text in
      fullChatViewModel.sendMessage(text: text)
    }
  }

  func updateUIView(_ uiView: ChatContainerView, context: Context) {}

}

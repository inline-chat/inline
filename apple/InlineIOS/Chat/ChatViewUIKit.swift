import InlineKit
import SwiftUI
import UIKit

class ChatContainerView: UIView {
  let peerId: Peer
  let chatId: Int64?

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
    view.chatId = chatId
    return view
  }()

  var composeEmbedView: ComposeEmbedView?

  lazy var composeEmbedViewWrapper: UIView = {
    let view = UIView()

    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var blurView: UIVisualEffectView = {
    let blurEffect = UIBlurEffect(style: .systemThickMaterial)
    let view = UIVisualEffectView(effect: blurEffect)
    view.backgroundColor = .clear
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var borderView: UIView = {
    let view = UIView()
    view.backgroundColor = .systemGray5
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var blurViewBottomConstraint: NSLayoutConstraint?

  init(peerId: Peer, chatId: Int64?) {
    self.peerId = peerId
    self.chatId = chatId

    super.init(frame: .zero)
    setupViews()
    setupObservers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var composeEmbedHeightConstraint: NSLayoutConstraint!
  private var composeEmbedBottomConstraint: NSLayoutConstraint?

  private func setupViews() {
    backgroundColor = .systemBackground

    addSubview(messagesCollectionView)
    addSubview(blurView)
    blurView.contentView.addSubview(borderView)
    addSubview(composeEmbedViewWrapper)
    addSubview(composeView)

    blurViewBottomConstraint = blurView.bottomAnchor.constraint(equalTo: bottomAnchor)

    keyboardLayoutGuide.followsUndockedKeyboard = true

    // initialize the height constraint
    composeEmbedHeightConstraint = composeEmbedViewWrapper.heightAnchor
      .constraint(equalToConstant: hasReply ? ComposeEmbedView.height : 0)
    addReplyView()
    NSLayoutConstraint.activate([
      messagesCollectionView.topAnchor.constraint(equalTo: topAnchor),
      messagesCollectionView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      messagesCollectionView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      messagesCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.topAnchor.constraint(
        equalTo: composeEmbedViewWrapper.topAnchor,
        constant: -ComposeView.textViewVerticalMargin
      ),
      blurViewBottomConstraint!,

      composeEmbedViewWrapper.bottomAnchor.constraint(equalTo: composeView.topAnchor),
      composeEmbedViewWrapper.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: ComposeView.textViewHorizantalMargin
      ),
      composeEmbedViewWrapper.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -ComposeView.textViewHorizantalMargin
      ),
      composeEmbedHeightConstraint,

      composeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ComposeView.textViewHorizantalMargin),
      composeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ComposeView.textViewHorizantalMargin),
      composeView.bottomAnchor.constraint(
        equalTo: keyboardLayoutGuide.topAnchor, constant: -ComposeView.textViewVerticalMargin
      ),
      borderView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor),
      borderView.trailingAnchor.constraint(equalTo: blurView.trailingAnchor),
      borderView.topAnchor.constraint(equalTo: blurView.topAnchor),
      borderView.heightAnchor.constraint(equalToConstant: 0.5),
    ])
  }

  private func setupObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(setReply),
      name: .init("ChatStateSetReplyCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clearReply),
      name: .init("ChatStateClearReplyCalled"),
      object: nil
    )
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

  var hasReply: Bool { ChatState.shared.getState(peer: peerId).replyingMessageId != nil }

  private func addReplyView() {
    let newComposeEmbedView = ComposeEmbedView(
      peerId: peerId,
      chatId: chatId ?? 0,
      messageId: ChatState.shared.getState(peer: peerId).replyingMessageId ?? 0
    )
    newComposeEmbedView.translatesAutoresizingMaskIntoConstraints = false
    composeEmbedViewWrapper.clipsToBounds = true
    composeEmbedViewWrapper.addSubview(newComposeEmbedView)

    NSLayoutConstraint.activate([
      newComposeEmbedView.leadingAnchor.constraint(equalTo: composeEmbedViewWrapper.leadingAnchor, constant: 6),
      newComposeEmbedView.trailingAnchor.constraint(equalTo: composeEmbedViewWrapper.trailingAnchor, constant: -6),
      newComposeEmbedView.bottomAnchor.constraint(equalTo: composeEmbedViewWrapper.bottomAnchor, constant: -4),
      newComposeEmbedView.heightAnchor.constraint(equalToConstant: ComposeEmbedView.height),
    ])

    composeEmbedView = newComposeEmbedView
  }

  @objc private func setReply() {
    composeEmbedView?.removeFromSuperview()
    addReplyView()
    layoutIfNeeded()

    composeEmbedHeightConstraint.constant = ComposeEmbedView.height

    UIView.animate(
      withDuration: 0.2,
      delay: 0,
      options: .curveEaseOut
    ) {
      self.layoutIfNeeded()
      self.composeView.textView.becomeFirstResponder()
    }
  }

  @objc private func clearReply() {
    composeEmbedHeightConstraint.constant = 0

    UIView.animate(withDuration: 0.2) {
      self.layoutIfNeeded()
    } completion: { _ in
      self.composeEmbedView?.isHidden = true
      self.composeEmbedView?.removeFromSuperview()
    }
  }

  private func handleComposeViewHeightChange(_ newHeight: CGFloat) {
    messagesCollectionView.updateComposeInset(composeHeight: newHeight)

    layoutIfNeeded()
  }
}

struct ChatViewUIKit: UIViewRepresentable {
  let peerId: Peer
  let chatId: Int64?
  @EnvironmentObject var data: DataManager

  func makeUIView(context: Context) -> ChatContainerView {
    ChatContainerView(peerId: peerId, chatId: chatId)
  }

  func updateUIView(_ uiView: ChatContainerView, context: Context) {}
}

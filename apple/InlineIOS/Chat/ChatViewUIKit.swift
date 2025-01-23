import InlineKit
import SwiftUI
import UIKit

class ChatContainerView: UIView {
  static var embedViewHeight: CGFloat = 60

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

  private lazy var composeEmbedHostingController: UIHostingController<ComposeEmbedViewSwiftUI> = {
    let hostingController = UIHostingController(
      rootView: ComposeEmbedViewSwiftUI(
        peerId: peerId, chatId: chatId ?? 0, messageId: ChatState.shared.getState(peer: peerId).replyingMessageId ?? 0
      ))
    hostingController.view.backgroundColor = .clear
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    return hostingController
  }()

  private lazy var blurView: UIVisualEffectView = {
    let blurEffect = UIBlurEffect(style: .systemThickMaterial)
    let view = UIVisualEffectView(effect: blurEffect)
    view.backgroundColor = .clear
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

  private var composeEmbedHeightConstraint: NSLayoutConstraint?
  private var composeEmbedBottomConstraint: NSLayoutConstraint?

  private func setupViews() {
    print("HAS REPLY ? \(hasReply)")
    backgroundColor = .systemBackground

    addSubview(messagesCollectionView)
    addSubview(blurView)
    addSubview(composeEmbedHostingController.view)
    addSubview(composeView)

    blurViewBottomConstraint = blurView.bottomAnchor.constraint(equalTo: bottomAnchor)
    composeEmbedHeightConstraint = composeEmbedHostingController.view.heightAnchor.constraint(
      equalToConstant: hasReply ? Self.embedViewHeight : 0)
    composeEmbedBottomConstraint = composeEmbedHostingController.view.bottomAnchor.constraint(
      equalTo: composeView.topAnchor)

    keyboardLayoutGuide.followsUndockedKeyboard = true

    //    NSLayoutConstraint.activate([
    //      composeEmbedHostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
    //      composeEmbedHostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
    //      composeEmbedHostingController.view.bottomAnchor.constraint(equalTo: composeView.topAnchor),
    //      composeEmbedHostingController.view.heightAnchor.constraint(equalToConstant: Self.embedViewHeight),
    //    ])

    //    composeEmbedHostingController.view.isHidden = !hasReply

    NSLayoutConstraint.activate([
      composeEmbedHostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      composeEmbedHostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      composeEmbedBottomConstraint!,
      composeEmbedHeightConstraint!,

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

    updateComposeEmbedViewState(isReplyActive: hasReply)

    //    // Initial state setup
    //    composeEmbedHostingController.view.alpha = hasReply ? 1 : 0
    //    composeEmbedHostingController.view.transform = hasReply ? .identity : CGAffineTransform(translationX: 0, y: 20)
  }

  private func setupObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateDidChange"),
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

  private func updateComposeEmbedViewState(isReplyActive: Bool) {
    let embedView = composeEmbedHostingController.view
    guard let embedView = embedView else { return }

    embedView.isHidden = !isReplyActive
    composeEmbedHeightConstraint?.constant = isReplyActive ? Self.embedViewHeight : 0

    layoutIfNeeded()
  }

  @objc private func replyStateChanged(_ notification: Notification) {
    let state = ChatState.shared.getState(peer: peerId)
    let isReplyActive = state.replyingMessageId != nil

    if isReplyActive {
      composeView.textView.becomeFirstResponder()

      let newHostingController = UIHostingController(
        rootView: ComposeEmbedViewSwiftUI(
          peerId: peerId,
          chatId: chatId ?? 0,
          messageId: state.replyingMessageId ?? 0
        )
      )

      newHostingController.view.backgroundColor = .clear
      newHostingController.view.translatesAutoresizingMaskIntoConstraints = false

      composeEmbedHostingController.view.removeFromSuperview()
      composeEmbedHostingController = newHostingController
      addSubview(composeEmbedHostingController.view)

      NSLayoutConstraint.activate([
        composeEmbedHostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
        composeEmbedHostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        composeEmbedHostingController.view.bottomAnchor.constraint(equalTo: composeView.topAnchor),
        composeEmbedHostingController.view.heightAnchor.constraint(equalToConstant: Self.embedViewHeight),
      ])

      layoutIfNeeded()
    }

    updateComposeEmbedViewState(isReplyActive: isReplyActive)
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
    return ChatContainerView(peerId: peerId, chatId: chatId)
  }

  func updateUIView(_ uiView: ChatContainerView, context: Context) {}
}

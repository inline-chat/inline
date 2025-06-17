import InlineKit
import SwiftUI
import UIKit

public class ChatContainerView: UIView {
  let peerId: Peer
  let chatId: Int64?
  let spaceId: Int64

  private lazy var messagesCollectionView: MessagesCollectionView = {
    let collectionView = MessagesCollectionView(peerId: peerId, chatId: chatId ?? 0, spaceId: spaceId)
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

  var mentionCompletionView: MentionCompletionView?

  lazy var mentionCompletionViewWrapper: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let blurView: UIVisualEffectView = {
    let effect = UIBlurEffect(style: .regular)
    let view = UIVisualEffectView(effect: effect)
    view.backgroundColor = ThemeManager.shared.selected.backgroundColor.withAlphaComponent(0.6)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var borderView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
//    view.backgroundColor = .systemGray5
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  let scrollButton = BlurCircleButton()

  private var blurViewBottomConstraint: NSLayoutConstraint?

  deinit {
    print("ChatView  deinit")
  }

  init(peerId: Peer, chatId: Int64?, spaceId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    self.spaceId = spaceId

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
  private var mentionCompletionHeightConstraint: NSLayoutConstraint!

  private func setupViews() {
    backgroundColor = ThemeManager.shared.selected.backgroundColor

    addSubview(messagesCollectionView)
    addSubview(blurView)
    blurView.contentView.addSubview(borderView)
    addSubview(composeEmbedViewWrapper)
    addSubview(mentionCompletionViewWrapper)
    addSubview(composeView)
    addSubview(scrollButton)
    scrollButton.isHidden = true
    blurViewBottomConstraint = blurView.bottomAnchor.constraint(equalTo: bottomAnchor)

    keyboardLayoutGuide.followsUndockedKeyboard = true

    // initialize the height constraint
    composeEmbedHeightConstraint = composeEmbedViewWrapper.heightAnchor
      .constraint(equalToConstant: hasEmbed ? ComposeEmbedView.height : 0)

    // initialize mention completion height constraint
    mentionCompletionHeightConstraint = mentionCompletionViewWrapper.heightAnchor
      .constraint(equalToConstant: 0)

    if hasEmbed {
      addReplyView()
    }

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
      composeEmbedViewWrapper.heightAnchor.constraint(
        greaterThanOrEqualToConstant: ComposeEmbedView.height
      ),
      mentionCompletionViewWrapper.bottomAnchor.constraint(equalTo: composeEmbedViewWrapper.topAnchor),
      mentionCompletionViewWrapper.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: ComposeView.textViewHorizantalMargin
      ),
      mentionCompletionViewWrapper.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -ComposeView.textViewHorizantalMargin
      ),
      mentionCompletionHeightConstraint,

      composeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ComposeView.textViewHorizantalMargin),
      composeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ComposeView.textViewHorizantalMargin),
      composeView.bottomAnchor.constraint(
        equalTo: keyboardLayoutGuide.topAnchor, constant: -ComposeView.textViewVerticalMargin
      ),
      borderView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor),
      borderView.trailingAnchor.constraint(equalTo: blurView.trailingAnchor),
      borderView.topAnchor.constraint(equalTo: blurView.topAnchor),
      borderView.heightAnchor.constraint(equalToConstant: 0.5),

      scrollButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      scrollButton.bottomAnchor.constraint(equalTo: blurView.topAnchor, constant: -10),

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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScrollToBottomChanged),
      name: .scrollToBottomChanged,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(setReply),
      name: .init("ChatStateSetEditingCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clearReply),
      name: .init("ChatStateClearEditingCalled"),
      object: nil
    )
  }

  @objc private func handleScrollToBottomChanged(_ notification: Notification) {
    guard let isAtBottom = notification.userInfo?["isAtBottom"] as? Bool else { return }

    scrollButton.layer.removeAllAnimations()
    scrollButton.isHidden = false

    let targetTransform: CGAffineTransform = isAtBottom ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
    let targetAlpha: CGFloat = isAtBottom ? 1.0 : 0.0

    UIView.animate(
      withDuration: 0.25,
      delay: 0,
      usingSpringWithDamping: 0.8,
      initialSpringVelocity: 0.5,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: {
        self.scrollButton.transform = targetTransform
        self.scrollButton.alpha = targetAlpha
      }
    )

    if !isAtBottom {
      scrollButton.isHidden = true
    }
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

  private var hasEmbed: Bool {
    let state = ChatState.shared.getState(peer: peerId)
    return state.replyingMessageId != nil || state.editingMessageId != nil
  }

  private func addReplyView() {
    let state = ChatState.shared.getState(peer: peerId)
    guard let messageId = state.replyingMessageId ?? state.editingMessageId else { return }

    let newComposeEmbedView = ComposeEmbedView(
      peerId: peerId,
      chatId: chatId ?? 0,
      messageId: messageId
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

  private func addMentionCompletionView() {
    let newMentionCompletionView = MentionCompletionView()
    newMentionCompletionView.translatesAutoresizingMaskIntoConstraints = false
    mentionCompletionViewWrapper.clipsToBounds = true
    mentionCompletionViewWrapper.addSubview(newMentionCompletionView)

    NSLayoutConstraint.activate([
      newMentionCompletionView.leadingAnchor.constraint(
        equalTo: mentionCompletionViewWrapper.leadingAnchor,
        constant: 6
      ),
      newMentionCompletionView.trailingAnchor.constraint(
        equalTo: mentionCompletionViewWrapper.trailingAnchor,
        constant: -6
      ),
      newMentionCompletionView.bottomAnchor.constraint(
        equalTo: mentionCompletionViewWrapper.bottomAnchor,
        constant: -4
      ),
      newMentionCompletionView.topAnchor.constraint(equalTo: mentionCompletionViewWrapper.topAnchor),
    ])

    mentionCompletionView = newMentionCompletionView
  }

  public func showMentionCompletion(_ completionView: MentionCompletionView, with height: CGFloat) {
    // Remove existing mention completion view if different
    if mentionCompletionView != completionView {
      mentionCompletionView?.removeFromSuperview()
      mentionCompletionView = completionView

      // Add the new completion view to wrapper
      completionView.translatesAutoresizingMaskIntoConstraints = false
      mentionCompletionViewWrapper.clipsToBounds = true
      mentionCompletionViewWrapper.addSubview(completionView)

      NSLayoutConstraint.activate([
        completionView.leadingAnchor.constraint(
          equalTo: mentionCompletionViewWrapper.leadingAnchor,
          constant: 6
        ),
        completionView.trailingAnchor.constraint(
          equalTo: mentionCompletionViewWrapper.trailingAnchor,
          constant: -6
        ),
        completionView.bottomAnchor.constraint(
          equalTo: mentionCompletionViewWrapper.bottomAnchor,
          constant: -4
        ),
        completionView.topAnchor.constraint(equalTo: mentionCompletionViewWrapper.topAnchor),
      ])
    }

    mentionCompletionHeightConstraint.constant = height
    completionView.show()

    UIView.animate(withDuration: 0.2) {
      self.layoutIfNeeded()
    }
  }

  func showMentionCompletion(with height: CGFloat) {
    if mentionCompletionView == nil {
      addMentionCompletionView()
    }

    mentionCompletionHeightConstraint.constant = height

    UIView.animate(withDuration: 0.2) {
      self.layoutIfNeeded()
    }
  }

  public func hideMentionCompletion() {
    mentionCompletionHeightConstraint.constant = 0

    UIView.animate(withDuration: 0.2) {
      self.layoutIfNeeded()
    } completion: { _ in
      self.mentionCompletionView?.removeFromSuperview()
      self.mentionCompletionView = nil
    }
  }

  @objc private func setReply() {
    composeEmbedView?.removeFromSuperview()
    addReplyView()
    layoutIfNeeded()

    composeEmbedHeightConstraint.constant = ComposeEmbedView.height

    UIView.animate(
      withDuration: 0.2,
      delay: 0.1
    ) {
      self.layoutIfNeeded()
      self.becomeFirstResponder()
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

      // Clear compose text if we were editing
      if ChatState.shared.getState(peer: self.peerId).editingMessageId != nil {
        self.composeView.textView.text = ""
        self.composeView.textView.becomeFirstResponder()
      }
    }
  }

  private func handleComposeViewHeightChange(_ newHeight: CGFloat) {
    messagesCollectionView.updateComposeInset(composeHeight: newHeight)

    layoutIfNeeded()
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
  }
}

struct ChatViewUIKit: UIViewRepresentable {
  let peerId: Peer
  let chatId: Int64?
  let spaceId: Int64
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var fullChatViewModel: FullChatViewModel

  func makeUIView(context: Context) -> ChatContainerView {
    let view = ChatContainerView(peerId: peerId, chatId: chatId, spaceId: spaceId)

    if let draftMessage = fullChatViewModel.chatItem?.dialog.draftMessage {
      view.composeView.loadDraft(from: draftMessage)
    }

    // Mark messages as read when view appears
    // UnreadManager.shared.readAll(peerId, chatId: chatId ?? 0)

    return view
  }

  func updateUIView(_ uiView: ChatContainerView, context: Context) {}
}

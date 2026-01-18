import InlineKit
import SwiftUI
import UIKit

public class ChatContainerView: UIView {
  let peerId: Peer
  let chatId: Int64?
  let spaceId: Int64

  private weak var edgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer?

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

  var mentionCompletionView: MentionCompletionView?

  lazy var mentionCompletionViewWrapper: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let composeContainerView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var composeBlurBackgroundView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false

    let gradientLayer = CAGradientLayer()
    let dynamicColor = UIColor { traitCollection in
      traitCollection.userInterfaceStyle == .dark
//        ? UIColor.red
//        : UIColor.red
        ? UIColor.systemBackground
        : UIColor.systemBackground
    }
    gradientLayer.colors = [
      dynamicColor.cgColor,
      dynamicColor.withAlphaComponent(0.5).cgColor,
      dynamicColor.withAlphaComponent(0.0).cgColor,
    ]

    gradientLayer.locations = [0, 0.8, 1]
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
    view.layer.insertSublayer(gradientLayer, at: 0)

    view.layer.name = "gradientLayer"

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

  private var composeContainerViewBottomConstraint: NSLayoutConstraint?

  deinit {
    edgePanGestureRecognizer?.removeTarget(self, action: #selector(handleEdgePan(_:)))
  }

  init(peerId: Peer, chatId: Int64?, spaceId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    self.spaceId = spaceId

    super.init(frame: .zero)
    setupViews()
    setupObservers()
    attachEdgePanHandlerIfNeeded()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()
    attachEdgePanHandlerIfNeeded()
  }

  private var mentionCompletionHeightConstraint: NSLayoutConstraint!

  private func setupViews() {
    backgroundColor = ThemeManager.shared.selected.backgroundColor

    addSubview(messagesCollectionView)
    addSubview(composeBlurBackgroundView)
    addSubview(composeContainerView)
    composeContainerView.addSubview(borderView)
    addSubview(mentionCompletionViewWrapper)
    addSubview(composeView)
    addSubview(scrollButton)
    scrollButton.isHidden = true
    composeContainerViewBottomConstraint = composeContainerView.bottomAnchor.constraint(equalTo: bottomAnchor)

    keyboardLayoutGuide.followsUndockedKeyboard = true

    // initialize mention completion height constraint
    mentionCompletionHeightConstraint = mentionCompletionViewWrapper.heightAnchor
      .constraint(equalToConstant: 0)

    NSLayoutConstraint.activate(
      [
        messagesCollectionView.topAnchor.constraint(equalTo: topAnchor),
        messagesCollectionView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
        messagesCollectionView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        messagesCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

        composeBlurBackgroundView.leadingAnchor.constraint(equalTo: composeContainerView.leadingAnchor),
        composeBlurBackgroundView.trailingAnchor.constraint(equalTo: composeContainerView.trailingAnchor),
        composeBlurBackgroundView.topAnchor.constraint(
          equalTo: composeContainerView.topAnchor,
          constant: -10
        ),
        composeBlurBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

        composeContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
        composeContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
        composeContainerView.topAnchor.constraint(
          equalTo: composeView.topAnchor,
          constant: -ComposeView.textViewVerticalMargin
        ),
        composeContainerViewBottomConstraint!,

        mentionCompletionViewWrapper.bottomAnchor.constraint(equalTo: composeView.topAnchor),
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
        borderView.leadingAnchor.constraint(equalTo: composeContainerView.leadingAnchor),
        borderView.trailingAnchor.constraint(equalTo: composeContainerView.trailingAnchor),
        borderView.topAnchor.constraint(equalTo: composeContainerView.topAnchor),
        borderView.heightAnchor.constraint(equalToConstant: 0.5),

        scrollButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        scrollButton.bottomAnchor.constraint(equalTo: composeContainerView.topAnchor, constant: -10),
      ]
    )
  }

  private func setupObservers() {
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
      selector: #selector(handleScrollToBottomUnreadChanged),
      name: .scrollToBottomUnreadChanged,
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

  @objc private func handleScrollToBottomUnreadChanged(_ notification: Notification) {
    guard let hasUnread = notification.userInfo?["hasUnread"] as? Bool else { return }
    scrollButton.setHasUnread(hasUnread)
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
      self.composeContainerViewBottomConstraint?.isActive = false
      self.composeContainerViewBottomConstraint = self.composeContainerView.bottomAnchor
        .constraint(equalTo: self.keyboardLayoutGuide.topAnchor)
      self.composeContainerViewBottomConstraint?.isActive = true
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
      self.composeContainerViewBottomConstraint?.isActive = false
      self.composeContainerViewBottomConstraint = self.composeContainerView.bottomAnchor
        .constraint(equalTo: self.bottomAnchor)
      self.composeContainerViewBottomConstraint?.isActive = true
      self.layoutIfNeeded()
    }
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

  private func handleComposeViewHeightChange(_ newHeight: CGFloat) {
    messagesCollectionView.updateComposeInset(composeHeight: newHeight)

    setNeedsLayout()
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    if let gradientLayer = composeBlurBackgroundView.layer.sublayers?
      .first(where: { $0 is CAGradientLayer }) as? CAGradientLayer
    {
      gradientLayer.frame = composeBlurBackgroundView.bounds
    }
  }

  override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)

    if traitCollection
      .hasDifferentColorAppearance(comparedTo: previousTraitCollection)
    {
      updateGradientColors()
    }
  }

  private func updateGradientColors() {
    if let gradientLayer = composeBlurBackgroundView.layer.sublayers?
      .first(where: { $0 is CAGradientLayer }) as? CAGradientLayer
    {
      let backgroundColor = UIColor.systemBackground
      gradientLayer.colors = [
        backgroundColor.resolvedColor(with: traitCollection).cgColor,
        backgroundColor.withAlphaComponent(0.0).resolvedColor(with: traitCollection).cgColor,
      ]
    }
  }

  private func attachEdgePanHandlerIfNeeded() {
    guard edgePanGestureRecognizer == nil else { return }

    // SwiftUI NavigationStack still hosts inside a UINavigationController; grab its back-swipe recognizer.
    guard let edgePan = findViewController()?.navigationController?.interactivePopGestureRecognizer
      as? UIScreenEdgePanGestureRecognizer
    else { return }

    edgePan.addTarget(self, action: #selector(handleEdgePan(_:)))
    edgePanGestureRecognizer = edgePan
  }

  @objc private func handleEdgePan(_ gesture: UIGestureRecognizer) {
    // Dismiss keyboard as soon as back-swipe begins and guard against auto-refocus after cancel.
    switch gesture.state {
    case .began:
      composeView.textView.isEditable = false
      composeView.textView.resignFirstResponder()

    case .ended, .cancelled, .failed:
      // Briefly disable editing so the system doesn't restore the first responder on cancellation.
      // Important note: Less than 0.3s would not work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self else { return }
        composeView.textView.isEditable = true
      }

    default:
      break
    }
  }

  private func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        return viewController
      }
      responder = nextResponder
    }
    return nil
  }
}

struct ChatViewUIKit: UIViewRepresentable {
  let peerId: Peer
  let chatId: Int64?
  let spaceId: Int64
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var fullChatViewModel: FullChatViewModel

  func makeUIView(context _: Context) -> ChatContainerView {
    let view = ChatContainerView(peerId: peerId, chatId: chatId, spaceId: spaceId)

    if let draftMessage = fullChatViewModel.chatItem?.dialog.draftMessage {
      view.composeView.loadDraft(from: draftMessage)
    }

    // Mark messages as read when view appears
    UnreadManager.shared.readAll(peerId, chatId: chatId ?? 0)

    return view
  }

  func updateUIView(_: ChatContainerView, context _: Context) {}
}

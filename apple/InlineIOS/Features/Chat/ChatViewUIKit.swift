import InlineKit
import SwiftUI
import UIKit

public class ChatContainerView: UIView {
  let peerId: Peer
  let chatId: Int64?
  let spaceId: Int64?
  private var peerUser: User?

  private lazy var keyboardDismissTapGestureRecognizer: UITapGestureRecognizer = {
    let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTapOutsideCompose))
    gesture.cancelsTouchesInView = false
    gesture.delegate = self
    return gesture
  }()

  private lazy var messagesCollectionView: MessagesCollectionView = {
    let collectionView = MessagesCollectionView(peerId: peerId, chatId: chatId ?? 0, spaceId: spaceId)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    return collectionView
  }()

  private lazy var pinnedHeaderView: PinnedMessageHeaderView = {
    let view = PinnedMessageHeaderView(peerId: peerId, chatId: chatId ?? 0)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onHeightChange = { [weak self] height in
      self?.pinnedHeaderHeightConstraint?.constant = height
      self?.messagesCollectionView.updatePinnedHeaderHeight(height)
    }
    return view
  }()

  lazy var composeView: ComposeView = {
    let view = ComposeView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onHeightChange = { [weak self] newHeight in
      self?.handleComposeViewHeightChange(newHeight)
    }
    view.peerId = peerId
    view.chatId = chatId
    view.spaceId = spaceId
    view.setPeerUser(peerUser)
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
  private var composeViewBottomConstraint: NSLayoutConstraint?
  private var pinnedHeaderHeightConstraint: NSLayoutConstraint?
  private var keyboardFrameBottomInset: CGFloat = 0

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  init(peerId: Peer, chatId: Int64?, spaceId: Int64?, peerUser: User?) {
    self.peerId = peerId
    self.chatId = chatId
    self.spaceId = spaceId
    self.peerUser = peerUser

    super.init(frame: .zero)
    setupViews()
    setupObservers()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()
  }

  func setPeerUser(_ user: User?) {
    guard peerUser != user else { return }
    peerUser = user
    composeView.setPeerUser(user)
  }

  private var mentionCompletionHeightConstraint: NSLayoutConstraint!

  private func setupViews() {
    backgroundColor = ThemeManager.shared.selected.backgroundColor

    addSubview(messagesCollectionView)
    addGestureRecognizer(keyboardDismissTapGestureRecognizer)
    addSubview(pinnedHeaderView)
    addSubview(composeBlurBackgroundView)
    addSubview(composeContainerView)
    composeContainerView.addSubview(borderView)
    addSubview(mentionCompletionViewWrapper)
    addSubview(composeView)
    addSubview(scrollButton)
    scrollButton.isHidden = true
    updateKeyboardAccessoryHeight(composeHeight: ComposeView.minHeight)
    let composeContainerBottomConstraint = composeContainerView.bottomAnchor.constraint(equalTo: bottomAnchor)
    let composeBottomConstraint = composeView.bottomAnchor.constraint(
      equalTo: bottomAnchor,
      constant: -ComposeView.textViewVerticalMargin
    )
    composeContainerViewBottomConstraint = composeContainerBottomConstraint
    composeViewBottomConstraint = composeBottomConstraint

    keyboardLayoutGuide.followsUndockedKeyboard = true

    // initialize mention completion height constraint
    mentionCompletionHeightConstraint = mentionCompletionViewWrapper.heightAnchor
      .constraint(equalToConstant: 0)
    pinnedHeaderHeightConstraint = pinnedHeaderView.heightAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate(
      [
        messagesCollectionView.topAnchor.constraint(equalTo: topAnchor),
        messagesCollectionView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
        messagesCollectionView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        messagesCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

        pinnedHeaderView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
        pinnedHeaderView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        pinnedHeaderView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: -4),
        pinnedHeaderHeightConstraint!,

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
        composeContainerBottomConstraint,

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
        composeBottomConstraint,
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
      selector: #selector(keyboardWillChangeFrame),
      name: UIResponder.keyboardWillChangeFrameNotification,
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

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
          let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
    else {
      KeyboardTrace.trace(
        "ChatContainerView",
        "keyboardFrame.missingPayload",
        view: self,
        notification: notification,
        details: keyboardTraceSummary
      )
      return
    }

    let oldBottomInset = keyboardFrameBottomInset
    let overlap = keyboardOverlap(with: keyboardFrame)
    let bottomInset = keyboardBottomInset(for: overlap)
    let isOpening = bottomInset > oldBottomInset + 0.5
    keyboardFrameBottomInset = bottomInset

    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: keyboardAnimationOptions(from: notification),
      animations: {
        self.applyKeyboardBottomInset(
          bottomInset,
          animated: duration > 0,
          keepAtBottom: isOpening
        )
        KeyboardTrace.trace(
          "ChatContainerView",
          "keyboardFrame.apply",
          view: self,
          notification: notification,
          details: "bottomInset=\(KeyboardTrace.format(bottomInset)) accessoryHeight=\(KeyboardTrace.format(self.keyboardAccessoryHeight)) \(self.keyboardTraceSummary)"
        )
      }
    )
  }

  private func keyboardAnimationOptions(from notification: Notification) -> UIView.AnimationOptions {
    var options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
    if let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
      options.insert(UIView.AnimationOptions(rawValue: UInt(truncating: curve) << 16))
    }
    return options
  }

  private func keyboardOverlap(with keyboardFrame: CGRect) -> CGFloat {
    let keyboardFrameInView = convert(keyboardFrame, from: nil)
    return max(0, bounds.maxY - keyboardFrameInView.minY)
  }

  private func keyboardBottomInset(for overlap: CGFloat) -> CGFloat {
    let accessoryHeight = composeView.textView.isKeyboardAccessoryVisible ? keyboardAccessoryHeight : 0
    return max(0, overlap - accessoryHeight)
  }

  @discardableResult
  private func setComposeBottomInset(_ bottomInset: CGFloat) -> Bool {
    let composeContainerConstant = -bottomInset
    let composeViewConstant = -(bottomInset + ComposeView.textViewVerticalMargin)
    guard composeContainerViewBottomConstraint?.constant != composeContainerConstant ||
          composeViewBottomConstraint?.constant != composeViewConstant
    else {
      return false
    }

    composeContainerViewBottomConstraint?.constant = composeContainerConstant
    composeViewBottomConstraint?.constant = composeViewConstant
    return true
  }

  private func applyKeyboardBottomInset(
    _ bottomInset: CGFloat,
    animated: Bool,
    keepAtBottom: Bool
  ) {
    setComposeBottomInset(bottomInset)
    messagesCollectionView.updateKeyboardInset(
      bottomInset,
      animated: animated,
      keepAtBottom: keepAtBottom
    )
    layoutIfNeeded()
  }

  private var keyboardAccessoryHeight: CGFloat {
    composeHeightWithMargins(composeView.composeHeightConstraint?.constant ?? ComposeView.minHeight)
  }

  private func updateKeyboardAccessoryHeight(composeHeight: CGFloat) {
    let height = composeHeightWithMargins(composeHeight)
    composeView.textView.updateKeyboardAccessoryHeight(height)
  }

  private func composeHeightWithMargins(_ composeHeight: CGFloat) -> CGFloat {
    composeHeight + ComposeView.textViewVerticalMargin * 2
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
    updateKeyboardAccessoryHeight(composeHeight: newHeight)
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

  @objc private func handleTapOutsideCompose() {
    guard composeView.textView.isFirstResponder else { return }
    KeyboardTrace.trace("ChatContainerView", "tapOutsideCompose", details: keyboardTraceSummary)
    composeView.textView.resignFirstResponder()
  }

  private var keyboardTraceSummary: String {
    [
      "composeFrame=\(KeyboardTrace.rect(composeView.frame))",
      "composeContainerFrame=\(KeyboardTrace.rect(composeContainerView.frame))",
      "keyboardGuide=\(KeyboardTrace.rect(keyboardLayoutGuide.layoutFrame))",
      "keyboardAccessoryHeight=\(KeyboardTrace.format(keyboardAccessoryHeight))",
      "keyboardAccessoryVisible=\(composeView.textView.isKeyboardAccessoryVisible)",
      "composeContainerBottomConstraint=\(KeyboardTrace.constraint(composeContainerViewBottomConstraint))",
      "composeViewBottomConstraint=\(KeyboardTrace.constraint(composeViewBottomConstraint))",
      "composeHeightConstraint=\(KeyboardTrace.format(composeView.composeHeightConstraint?.constant ?? 0))",
      KeyboardTrace.textViewState(composeView.textView),
    ].joined(separator: " ")
  }

}

extension ChatContainerView: UIGestureRecognizerDelegate {
  public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard gestureRecognizer === keyboardDismissTapGestureRecognizer else { return true }
    guard composeView.textView.isFirstResponder else { return false }
    guard let touchedView = touch.view else { return true }

    if touchedView.isDescendant(of: composeView) ||
      touchedView.isDescendant(of: mentionCompletionViewWrapper) ||
      touchedView.isDescendant(of: scrollButton)
    {
      return false
    }

    return true
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    gestureRecognizer === keyboardDismissTapGestureRecognizer ||
      otherGestureRecognizer === keyboardDismissTapGestureRecognizer
  }
}

struct ChatViewUIKit: UIViewRepresentable {
  let peerId: Peer
  let chatId: Int64?
  let spaceId: Int64?
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var fullChatViewModel: FullChatViewModel

  func makeUIView(context _: Context) -> ChatContainerView {
    let view = ChatContainerView(peerId: peerId, chatId: chatId, spaceId: spaceId, peerUser: fullChatViewModel.peerUser)

    if let draftMessage = fullChatViewModel.chatItem?.dialog.draftMessage {
      view.composeView.loadDraft(from: draftMessage)
    }

    // Mark messages as read when view appears
    UnreadManager.shared.readAll(peerId, chatId: chatId ?? 0)

    return view
  }

  func updateUIView(_ view: ChatContainerView, context _: Context) {
    view.setPeerUser(fullChatViewModel.peerUser)
  }
}

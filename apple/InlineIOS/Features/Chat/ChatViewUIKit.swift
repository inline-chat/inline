import InlineKit
import SwiftUI
import UIKit

public class ChatContainerView: UIView {
  let peerId: Peer
  let chatId: Int64?
  let spaceId: Int64?
  private var peerUser: User?

  private weak var edgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer?

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

  private lazy var borderView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
//    view.backgroundColor = .systemGray5
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  let scrollButton = BlurCircleButton()

  private var usesIOS27KeyboardWorkaround: Bool {
    if #available(iOS 27.0, *) {
      return true
    }
    return false
  }

  private lazy var keyboardTrackingAccessoryView: KeyboardTrackingAccessoryView = {
    let view = KeyboardTrackingAccessoryView()
    view.onFrameChange = { [weak self] view in
      self?.updateComposeForKeyboardAccessory(view)
    }
    return view
  }()

  private var composeContainerViewBottomConstraint: NSLayoutConstraint?
  private var pinnedHeaderHeightConstraint: NSLayoutConstraint?

  deinit {
    NotificationCenter.default.removeObserver(self)
    edgePanGestureRecognizer?.removeTarget(self, action: #selector(handleEdgePan(_:)))
  }

  init(peerId: Peer, chatId: Int64?, spaceId: Int64?, peerUser: User?) {
    self.peerId = peerId
    self.chatId = chatId
    self.spaceId = spaceId
    self.peerUser = peerUser

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

  func setPeerUser(_ user: User?) {
    guard peerUser != user else { return }
    peerUser = user
    composeView.setPeerUser(user)
  }

  private var mentionCompletionHeightConstraint: NSLayoutConstraint!

  private func setupViews() {
    backgroundColor = ThemeManager.shared.selected.backgroundColor

    addSubview(messagesCollectionView)
    messagesCollectionView.addGestureRecognizer(keyboardDismissTapGestureRecognizer)
    addSubview(pinnedHeaderView)
    addSubview(composeContainerView)
    composeContainerView.addSubview(borderView)
    addSubview(mentionCompletionViewWrapper)
    addSubview(composeView)
    addSubview(scrollButton)

    if usesIOS27KeyboardWorkaround {
      composeView.textView.setKeyboardTrackingAccessoryView(keyboardTrackingAccessoryView)
    } else {
      keyboardLayoutGuide.followsUndockedKeyboard = true
    }

    scrollButton.isHidden = true
    composeContainerViewBottomConstraint = composeContainerView.bottomAnchor.constraint(equalTo: bottomAnchor)

    // initialize mention completion height constraint
    mentionCompletionHeightConstraint = mentionCompletionViewWrapper.heightAnchor
      .constraint(equalToConstant: 0)
    pinnedHeaderHeightConstraint = pinnedHeaderView.heightAnchor.constraint(equalToConstant: 0)
    let composeBottomAnchor = usesIOS27KeyboardWorkaround
      ? composeContainerView.bottomAnchor
      : keyboardLayoutGuide.topAnchor

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
          equalTo: composeBottomAnchor,
          constant: -ComposeView.textViewVerticalMargin
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
    if usesIOS27KeyboardWorkaround {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(keyboardFrameWillChange),
        name: UIResponder.keyboardWillChangeFrameNotification,
        object: nil
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(keyboardFrameDidChange),
        name: UIResponder.keyboardDidChangeFrameNotification,
        object: nil
      )
    } else {
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
    guard !usesIOS27KeyboardWorkaround,
          let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
    else {
      return
    }

    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: .curveEaseOut
    ) {
      self.setComposeContainerBottom(to: self.keyboardLayoutGuide.topAnchor)
      self.layoutIfNeeded()
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    guard !usesIOS27KeyboardWorkaround,
          let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
    else {
      return
    }

    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: .curveEaseIn
    ) {
      self.setComposeContainerBottom(to: self.bottomAnchor)
      self.layoutIfNeeded()
    }
  }

  @objc private func keyboardFrameWillChange(_ notification: Notification) {
    updateComposeForKeyboardFrame(notification, animated: true)
  }

  @objc private func keyboardFrameDidChange(_ notification: Notification) {
    updateComposeForKeyboardFrame(notification, animated: false)
  }

  private func updateComposeForKeyboardFrame(_ notification: Notification, animated: Bool) {
    guard usesIOS27KeyboardWorkaround,
          window != nil,
          let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else {
      return
    }

    if composeView.textView.isFirstResponder {
      keyboardTrackingAccessoryView.resumeTracking()
    }

    let inset = keyboardOverlap(with: keyboardFrame)
    let update = {
      guard self.setComposeKeyboardInset(inset) else { return }
      self.layoutIfNeeded()
    }

    guard animated,
          let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
          duration > 0
    else {
      UIView.performWithoutAnimation(update)
      return
    }

    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: keyboardAnimationOptions(from: notification),
      animations: update
    )
  }

  private func updateComposeForKeyboardAccessory(_ accessoryView: KeyboardTrackingAccessoryView) {
    guard usesIOS27KeyboardWorkaround,
          window != nil,
          composeView.textView.isFirstResponder,
          let keyboardTop = accessoryView.keyboardTop(in: self)
    else {
      return
    }

    let inset = normalizedKeyboardInset(fromKeyboardTop: keyboardTop)
    UIView.performWithoutAnimation {
      guard self.setComposeKeyboardInset(inset) else { return }
      self.layoutIfNeeded()
    }
  }

  private func keyboardOverlap(with keyboardFrame: CGRect) -> CGFloat {
    let keyboardFrameInView = convert(keyboardFrame, from: nil)
    return normalizedKeyboardInset(fromKeyboardTop: keyboardFrameInView.minY)
  }

  private func normalizedKeyboardInset(fromKeyboardTop keyboardTop: CGFloat) -> CGFloat {
    min(bounds.height, max(0, bounds.maxY - keyboardTop))
  }

  @discardableResult
  private func setComposeKeyboardInset(_ inset: CGFloat) -> Bool {
    let constant = -inset
    guard abs((composeContainerViewBottomConstraint?.constant ?? 0) - constant) > 0.5 else { return false }
    composeContainerViewBottomConstraint?.constant = constant
    return true
  }

  private func setComposeContainerBottom(to anchor: NSLayoutYAxisAnchor) {
    composeContainerViewBottomConstraint?.isActive = false
    composeContainerViewBottomConstraint = composeContainerView.bottomAnchor.constraint(equalTo: anchor)
    composeContainerViewBottomConstraint?.isActive = true
  }

  private func keyboardAnimationOptions(from notification: Notification) -> UIView.AnimationOptions {
    var options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
    if let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
      options.insert(UIView.AnimationOptions(rawValue: UInt(truncating: curve) << 16))
    }
    return options
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

  @objc private func handleTapOutsideCompose() {
    guard composeView.textView.isFirstResponder else { return }
    composeView.textView.resignFirstResponder()
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

private final class KeyboardTrackingAccessoryView: UIView {
  var onFrameChange: ((KeyboardTrackingAccessoryView) -> Void)?

  private var displayLink: CADisplayLink?
  private var lastScreenMaxY: CGFloat?

  override init(frame: CGRect) {
    super.init(frame: CGRect(origin: frame.origin, size: CGSize(width: frame.width, height: 1)))
    backgroundColor = .clear
    isUserInteractionEnabled = false
    autoresizingMask = [.flexibleWidth]
  }

  convenience init() {
    self.init(frame: CGRect(x: 0, y: 0, width: 0, height: 1))
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopDisplayLink()
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 1)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()

    if window == nil {
      stopDisplayLink()
      lastScreenMaxY = nil
    } else {
      resumeTracking()
    }
  }

  func resumeTracking() {
    guard window != nil else { return }
    startDisplayLink()
    _ = notifyIfNeeded(force: true)
  }

  func keyboardTop(in ownerView: UIView) -> CGFloat? {
    guard let screenFrame = currentScreenFrame() else { return nil }
    let frameInOwner = ownerView.convert(screenFrame, from: nil)
    return frameInOwner.maxY
  }

  private func startDisplayLink() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func displayLinkTick() {
    notifyIfNeeded()
  }

  @discardableResult
  private func notifyIfNeeded(force: Bool = false) -> Bool {
    guard let screenFrame = currentScreenFrame() else { return false }
    let screenMaxY = screenFrame.maxY
    guard force || abs(screenMaxY - (lastScreenMaxY ?? .greatestFiniteMagnitude)) > 0.5 else { return false }
    lastScreenMaxY = screenMaxY
    onFrameChange?(self)
    return true
  }

  private func currentScreenFrame() -> CGRect? {
    guard let window else { return nil }

    // The model frame can lag during interactive keyboard movement; sample presentation instead.
    let currentLayer = layer.presentation() ?? layer
    let frameInWindow = currentLayer.convert(currentLayer.bounds, to: window.layer)
    return window.convert(frameInWindow, to: nil)
  }
}

extension ChatContainerView: UIGestureRecognizerDelegate {
  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
  ) -> Bool {
    gestureRecognizer === keyboardDismissTapGestureRecognizer
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

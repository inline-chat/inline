import InlineKit
import InlineProtocol
import SwiftUI
import UIKit

public class ChatContainerView: UIView {
  var onRenameThread: (() -> Bool)?
  let peerId: InlineKit.Peer
  let chatId: Int64?
  let spaceId: Int64?
  private var collapsedMaxId: Int64?
  private let isPreview: Bool
  private(set) var theme: IOSThemeSnapshot
  private var lastAppliedDraftSignature: DraftSignature?
  private var lastRequestedFocus: (messageID: Int64, revision: Int)?

  private struct DraftSignature: Equatable {
    let text: String
    let entitiesData: Data?

    init(_ draftMessage: DraftMessage) {
      text = draftMessage.text
      entitiesData = draftMessage.hasEntities ? (try? draftMessage.entities.serializedData()) : nil
    }
  }

  private enum ComposeBottomMode {
    case safeArea
    case keyboard
  }

  private weak var edgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer?
  private var restoresComposeFocusAfterContextMenu = false
  private lazy var sendAnimationCoordinator: SendMessageAnimationCoordinator? = isPreview
    ? nil
    : SendMessageAnimationCoordinator(hostView: self)

  private lazy var keyboardDismissTapGestureRecognizer: UITapGestureRecognizer = {
    let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTapOutsideCompose))
    gesture.cancelsTouchesInView = false
    gesture.delegate = self
    return gesture
  }()

  private lazy var messagesCollectionView: MessagesCollectionView = {
    let collectionView = MessagesCollectionView(
      peerId: peerId,
      chatId: chatId ?? 0,
      spaceId: spaceId,
      collapsedMaxId: collapsedMaxId,
      isPreview: isPreview,
      sendAnimationCoordinator: sendAnimationCoordinator,
      theme: theme
    )
    if !isPreview {
      collectionView.onContextMenuWillDisplay = { [weak self] in
        guard let self else { return }
        restoresComposeFocusAfterContextMenu = restoresComposeFocusAfterContextMenu
          || composeView.textView.isFirstResponder
        // Cancel an already-tracking background tap as well as rejecting new
        // taps. Otherwise the long-press touch-up can dismiss the keyboard.
        keyboardDismissTapGestureRecognizer.isEnabled = false
      }
      collectionView.onContextMenuDidEnd = { [weak self] in
        self?.restoreComposeFocusAfterContextMenu()
      }
      collectionView.onScrollAffordanceChanged = { [weak self] state in
        self?.scrollButton.setVisible(state.isVisible)
        self?.scrollButton.setHasUnread(state.hasUnread)
      }
    }
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
    view.onOpenMessage = { [weak self] messageID in
      self?.messagesCollectionView.scrollToMessageWhenAvailable(messageID)
    }
    return view
  }()

  lazy var composeView: ComposeView = {
    let view = ComposeView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onHeightChange = { [weak self] newHeight, animation in
      self?.handleComposeViewHeightChange(newHeight, animation: animation)
    }
    view.peerId = peerId
    view.chatId = chatId
    view.spaceId = spaceId
    view.sendAnimationCoordinator = sendAnimationCoordinator
    view.executeInlineCommand = { [weak self] action in
      guard let self else { return nil }
      switch action {
      case .renameThread:
        guard onRenameThread?() == true else { return nil }
        return .completed
      case .collapseHistory:
        guard let maxID = messagesCollectionView.highestPositiveMessageId else { return nil }
        try await messagesCollectionView.collapseHistory(maxID: maxID)
        return .completed
      case .createSubthread:
        guard let chatId else { return nil }
        let result = try await LocalThreadCommandService.createAndOpen(parentChatId: chatId) { transaction in
          try await Api.realtime.send(transaction)
        }
        return .openThread(result)
      }
    }
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
  private var composeBottomMode: ComposeBottomMode = .safeArea
  private var isComposeKeyboardVisible = false
  private var pinnedHeaderHeightConstraint: NSLayoutConstraint?

  isolated deinit {
    sendAnimationCoordinator?.cancelAll()
    NotificationCenter.default.removeObserver(self)
    edgePanGestureRecognizer?.removeTarget(self, action: #selector(handleEdgePan(_:)))
  }

  init(
    peerId: InlineKit.Peer,
    chatId: Int64?,
    spaceId: Int64?,
    collapsedMaxId: Int64? = nil,
    isPreview: Bool = false,
    theme: IOSThemeSnapshot
  ) {
    self.peerId = peerId
    self.chatId = chatId
    self.spaceId = spaceId
    self.collapsedMaxId = collapsedMaxId
    self.isPreview = isPreview
    self.theme = theme

    super.init(frame: .zero)
    setupViews()
    if !isPreview {
      setupObservers()
      attachEdgePanHandlerIfNeeded()
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      sendAnimationCoordinator?.cancelAll()
    }
    sendAnimationCoordinator?.setHostView(window == nil ? nil : self)
    sendAnimationCoordinator?.setSourceLayoutView(window == nil ? nil : messagesCollectionView)
    if !isPreview {
      attachEdgePanHandlerIfNeeded()
      resetComposeToSafeAreaIfKeyboardClosed()
    }
  }

  func loadDraftIfNeeded(_ draftMessage: DraftMessage?) {
    guard !isPreview else { return }
    guard let draftMessage else {
      lastAppliedDraftSignature = nil
      return
    }

    let signature = DraftSignature(draftMessage)
    guard lastAppliedDraftSignature != signature else { return }
    guard !Drafts.shared.shouldSuppressDraftRestoration(for: peerId) else { return }
    lastAppliedDraftSignature = signature
    composeView.loadDraft(from: draftMessage)
  }

  func focusMessage(_ messageID: Int64?, requestRevision: Int) {
    guard let messageID else {
      lastRequestedFocus = nil
      messagesCollectionView.cancelPendingMessageFocus()
      return
    }
    guard lastRequestedFocus?.messageID != messageID || lastRequestedFocus?.revision != requestRevision else { return }
    lastRequestedFocus = (messageID, requestRevision)
    messagesCollectionView.scrollToMessageWhenAvailable(messageID)
  }

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    guard self.collapsedMaxId != collapsedMaxId else { return }
    self.collapsedMaxId = collapsedMaxId
    messagesCollectionView.setCollapsedMaxId(collapsedMaxId)
  }

  func applyTheme(_ theme: IOSThemeSnapshot) {
    guard self.theme != theme else { return }
    self.theme = theme
    backgroundColor = theme.chatCanvas.uiColor
    tintColor = theme.primary.uiColor
    composeView.tintColor = theme.primary.uiColor
    pinnedHeaderView.tintColor = theme.primary.uiColor
    scrollButton.tintColor = theme.primary.uiColor
    messagesCollectionView.applyTheme(theme)
  }

  private var mentionCompletionHeightConstraint: NSLayoutConstraint!

  private func setupViews() {
    backgroundColor = theme.chatCanvas.uiColor
    tintColor = theme.primary.uiColor

    addSubview(messagesCollectionView)
    sendAnimationCoordinator?.setSourceLayoutView(messagesCollectionView)
    addSubview(pinnedHeaderView)

    pinnedHeaderHeightConstraint = pinnedHeaderView.heightAnchor.constraint(equalToConstant: 0)
    let commonConstraints = [
      messagesCollectionView.topAnchor.constraint(equalTo: topAnchor),
      messagesCollectionView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      messagesCollectionView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      messagesCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

      pinnedHeaderView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      pinnedHeaderView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      pinnedHeaderView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: -4),
      pinnedHeaderHeightConstraint!,
    ]

    if isPreview {
      isUserInteractionEnabled = false
      NSLayoutConstraint.activate(commonConstraints)
      return
    }

    messagesCollectionView.addGestureRecognizer(keyboardDismissTapGestureRecognizer)
    addSubview(composeContainerView)
    composeContainerView.addSubview(borderView)
    addSubview(mentionCompletionViewWrapper)
    addSubview(composeView)
    addSubview(scrollButton)
    scrollButton.onTap = { [weak self] in
      self?.messagesCollectionView.scrollToBottom()
    }

    if usesIOS27KeyboardWorkaround {
      composeView.textView.setKeyboardTrackingAccessoryView(keyboardTrackingAccessoryView)
    } else {
      keyboardLayoutGuide.followsUndockedKeyboard = true
    }

    composeContainerViewBottomConstraint = composeContainerView.bottomAnchor
      .constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)

    // initialize mention completion height constraint
    mentionCompletionHeightConstraint = mentionCompletionViewWrapper.heightAnchor
      .constraint(equalToConstant: 0)
    let composeLeadingAnchor = IPadNavigationLane.isEnabled ? safeAreaLayoutGuide.leadingAnchor : leadingAnchor
    let composeTrailingAnchor = IPadNavigationLane.isEnabled ? safeAreaLayoutGuide.trailingAnchor : trailingAnchor
    NSLayoutConstraint.activate(
      commonConstraints + [
        composeContainerView.leadingAnchor.constraint(equalTo: composeLeadingAnchor),
        composeContainerView.trailingAnchor.constraint(equalTo: composeTrailingAnchor),
        composeContainerView.topAnchor.constraint(
          equalTo: composeView.topAnchor,
          constant: -ComposeView.textViewVerticalMargin
        ),
        composeContainerViewBottomConstraint!,

        mentionCompletionViewWrapper.bottomAnchor.constraint(equalTo: composeView.topAnchor),
        mentionCompletionViewWrapper.leadingAnchor.constraint(
          equalTo: composeLeadingAnchor,
          constant: ComposeView.textViewHorizantalMargin
        ),
        mentionCompletionViewWrapper.trailingAnchor.constraint(
          equalTo: composeTrailingAnchor,
          constant: -ComposeView.textViewHorizantalMargin
        ),
        mentionCompletionHeightConstraint,

        composeView.leadingAnchor.constraint(
          equalTo: composeLeadingAnchor,
          constant: ComposeView.textViewHorizantalMargin
        ),
        composeView.trailingAnchor.constraint(
          equalTo: composeTrailingAnchor,
          constant: -ComposeView.textViewHorizantalMargin
        ),
        composeView.bottomAnchor.constraint(
          equalTo: composeContainerView.bottomAnchor,
          constant: -ComposeView.textViewVerticalMargin
        ),
        borderView.leadingAnchor.constraint(equalTo: composeContainerView.leadingAnchor),
        borderView.trailingAnchor.constraint(equalTo: composeContainerView.trailingAnchor),
        borderView.topAnchor.constraint(equalTo: composeContainerView.topAnchor),
        borderView.heightAnchor.constraint(equalToConstant: 0.5),

        // The hit target is 44pt while the visible glass is 34pt. Insets preserve
        // the existing 10pt visual spacing from the trailing and compose edges.
        scrollButton.trailingAnchor.constraint(equalTo: composeTrailingAnchor, constant: -5),
        scrollButton.bottomAnchor.constraint(equalTo: composeContainerView.topAnchor, constant: -5),
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
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  @objc private func keyboardWillShow(_ notification: Notification) {
    guard !usesIOS27KeyboardWorkaround else {
      return
    }

    let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0

    guard composeView.textView.isFirstResponder else {
      animateComposeSafeAreaReset(duration: duration, options: .curveEaseIn)
      return
    }

    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: .curveEaseOut
    ) {
      self.isComposeKeyboardVisible = true
      self.setComposeContainerBottom(to: self.keyboardLayoutGuide.topAnchor, mode: .keyboard)
      self.layoutIfNeeded()
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    guard !usesIOS27KeyboardWorkaround else {
      return
    }

    let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
    animateComposeSafeAreaReset(duration: duration, options: .curveEaseIn)
  }

  @objc private func applicationDidBecomeActive() {
    DispatchQueue.main.async { [weak self] in
      self?.resetComposeToSafeAreaIfKeyboardClosed()
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

    let isComposeFocused = composeView.textView.isFirstResponder

    if isComposeFocused {
      keyboardTrackingAccessoryView.resumeTracking()
    }

    guard let inset = keyboardOverlap(with: keyboardFrame) else {
      if !isComposeFocused {
        animateComposeSafeAreaReset(animated: animated, notification: notification)
      }
      return
    }

    let targetInset = isComposeFocused ? inset : 0
    let update = {
      guard self.setComposeKeyboardInset(targetInset) else { return }
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

    guard let inset = normalizedKeyboardInset(fromKeyboardTop: keyboardTop) else { return }
    UIView.performWithoutAnimation {
      guard self.setComposeKeyboardInset(inset) else { return }
      self.layoutIfNeeded()
    }
  }

  private func keyboardOverlap(with keyboardFrame: CGRect) -> CGFloat? {
    guard isFinite(keyboardFrame) else { return nil }
    let keyboardFrameInView = convert(keyboardFrame, from: nil)
    return normalizedKeyboardInset(fromKeyboardTop: keyboardFrameInView.minY)
  }

  private func normalizedKeyboardInset(fromKeyboardTop keyboardTop: CGFloat) -> CGFloat? {
    guard bounds.height > 0,
          bounds.maxY.isFinite,
          keyboardTop.isFinite
    else {
      return nil
    }

    let inset = bounds.maxY - keyboardTop
    if inset <= 0.5 {
      return 0
    }

    let maxInset = max(0, bounds.height - ComposeView.minHeight - (ComposeView.textViewVerticalMargin * 2))
    // Foreground transitions can briefly report a keyboard top at the screen edge while the keyboard is closed.
    guard inset <= maxInset else {
      return nil
    }

    return min(bounds.height, inset)
  }

  private func isFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite
      && rect.origin.y.isFinite
      && rect.size.width.isFinite
      && rect.size.height.isFinite
  }

  @discardableResult
  private func setComposeKeyboardInset(_ inset: CGFloat) -> Bool {
    let didResetMode = setComposeContainerBottom(to: safeAreaLayoutGuide.bottomAnchor, mode: .safeArea)
    let insetFromSafeArea = max(0, inset - safeAreaInsets.bottom)
    let constant = -insetFromSafeArea
    let wasKeyboardVisible = isComposeKeyboardVisible
    isComposeKeyboardVisible = inset > 0.5
    guard didResetMode || abs((composeContainerViewBottomConstraint?.constant ?? 0) - constant) > 0.5 else {
      return wasKeyboardVisible != isComposeKeyboardVisible
    }
    composeContainerViewBottomConstraint?.constant = constant
    return true
  }

  @discardableResult
  private func setComposeSafeAreaBottom() -> Bool {
    let didResetMode = setComposeContainerBottom(to: safeAreaLayoutGuide.bottomAnchor, mode: .safeArea)
    let wasKeyboardVisible = isComposeKeyboardVisible
    isComposeKeyboardVisible = false
    guard abs(composeContainerViewBottomConstraint?.constant ?? 0) > 0.5 else {
      return didResetMode || wasKeyboardVisible
    }
    composeContainerViewBottomConstraint?.constant = 0
    return true
  }

  private func resetComposeToSafeAreaIfKeyboardClosed() {
    guard window != nil else { return }
    guard !composeView.textView.isFirstResponder || !isComposeKeyboardVisible else { return }
    UIView.performWithoutAnimation {
      guard self.setComposeSafeAreaBottom() else { return }
      self.layoutIfNeeded()
    }
  }

  private func animateComposeSafeAreaReset(
    animated: Bool = true,
    duration: Double,
    options: UIView.AnimationOptions
  ) {
    let update = {
      guard self.setComposeSafeAreaBottom() else { return }
      self.layoutIfNeeded()
    }

    guard animated, duration > 0 else {
      UIView.performWithoutAnimation(update)
      return
    }

    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: options,
      animations: update
    )
  }

  private func animateComposeSafeAreaReset(animated: Bool, notification: Notification) {
    let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
    animateComposeSafeAreaReset(
      animated: animated,
      duration: duration,
      options: keyboardAnimationOptions(from: notification)
    )
  }

  @discardableResult
  private func setComposeContainerBottom(to anchor: NSLayoutYAxisAnchor, mode: ComposeBottomMode) -> Bool {
    guard composeBottomMode != mode else { return false }
    composeContainerViewBottomConstraint?.isActive = false
    composeContainerViewBottomConstraint = composeContainerView.bottomAnchor.constraint(equalTo: anchor)
    composeContainerViewBottomConstraint?.isActive = true
    composeBottomMode = mode
    return true
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

  private func handleComposeViewHeightChange(
    _ newHeight: CGFloat,
    animation: ComposeHeightChangeAnimation
  ) {
    let animatedForSend = composeView.consumePendingSendAnimationHeightChange()
    if animatedForSend {
      SendMessageAnimationDiagnostics.event(
        "compose height-change-deferred-to-list newHeight=\(String(format: "%.1f", newHeight))"
      )
      messagesCollectionView.deferComposeInsetForPendingSendAnimation(composeHeight: newHeight)
    } else {
      messagesCollectionView.updateComposeInset(
        composeHeight: newHeight,
        animation: animation
      )
    }

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
      messagesCollectionView.cancelContextMenuKeyboardRestoration()
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
    guard !messagesCollectionView.isContextMenuInteractionActive,
          composeView.textView.isFirstResponder else { return }
    messagesCollectionView.cancelContextMenuKeyboardRestoration()
    composeView.textView.resignFirstResponder()
  }

  private func restoreComposeFocusAfterContextMenu() {
    let shouldRestore = restoresComposeFocusAfterContextMenu
    restoresComposeFocusAfterContextMenu = false
    keyboardDismissTapGestureRecognizer.isEnabled = true

    // Actions that navigate or present a sheet own focus from this point on.
    guard shouldRestore,
          window?.isKeyWindow == true,
          composeView.textView.isEditable,
          !composeView.textView.isFirstResponder,
          let controller = findViewController(),
          !controller.isBeingDismissed,
          !controller.isMovingFromParent,
          controller.presentedViewController == nil,
          controller.navigationController?.presentedViewController == nil,
          controller.navigationController.map({ $0.topViewController === controller }) ?? true
    else { return }
    // Keyboard notifications can arrive after the menu animator completes.
    messagesCollectionView.preserveContextMenuViewportForKeyboardRestoration()
    if !composeView.textView.becomeFirstResponder() {
      messagesCollectionView.cancelContextMenuKeyboardRestoration()
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
    shouldReceive touch: UITouch
  ) -> Bool {
    guard gestureRecognizer === keyboardDismissTapGestureRecognizer else { return true }
    guard !messagesCollectionView.isContextMenuInteractionActive else { return false }

    // A date tap owns navigation. Dismissing the keyboard on the same tap can
    // change the list's insets and cancel the scroll started by the button.
    var touchedView = touch.view
    while let view = touchedView {
      if view is DateSeparatorView {
        return false
      }
      if view === messagesCollectionView {
        break
      }
      touchedView = view.superview
    }
    return true
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
  ) -> Bool {
    gestureRecognizer === keyboardDismissTapGestureRecognizer
  }
}

struct ChatViewUIKit: UIViewRepresentable {
  let peerId: InlineKit.Peer
  let chatId: Int64?
  let spaceId: Int64?
  let draftMessage: DraftMessage?
  let focusMessageID: Int64?
  let focusRequestRevision: Int
  let collapsedMaxId: Int64?
  let isPreview: Bool
  let theme: IOSThemeSnapshot
  var onRenameThread: (() -> Bool)? = nil

  func makeUIView(context _: Context) -> ChatContainerView {
    let view = ChatContainerView(
      peerId: peerId,
      chatId: chatId,
      spaceId: spaceId,
      collapsedMaxId: collapsedMaxId,
      isPreview: isPreview,
      theme: theme
    )
    view.onRenameThread = isPreview ? nil : onRenameThread
    if !isPreview {
      view.loadDraftIfNeeded(draftMessage)
      view.focusMessage(focusMessageID, requestRevision: focusRequestRevision)
    }

    return view
  }

  func updateUIView(_ view: ChatContainerView, context _: Context) {
    view.onRenameThread = isPreview ? nil : onRenameThread
    view.applyTheme(theme)
    view.setCollapsedMaxId(collapsedMaxId)
    if !isPreview {
      view.loadDraftIfNeeded(draftMessage)
      view.focusMessage(focusMessageID, requestRevision: focusRequestRevision)
    }
  }
}

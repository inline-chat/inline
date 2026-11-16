import InlineIOSUI
import InlineKit
import InlineProtocol
import SwiftUI
import UIKit

public class ChatContainerView: UIView {
  var onRenameThread: (() -> Bool)?
  var onOpenVoiceMessage: ((AudioPlaybackOpenTarget, @escaping (Int64) -> Void) -> Void)?
  var canPresentVoicePlaybackError: (() -> Bool)?
  let peerId: InlineKit.Peer
  let chatId: Int64?
  let spaceId: Int64?
  private var collapsedMaxId: Int64?
  /// The first message window, read before this view was built; nil makes the list read it.
  private let initialMessages: MessagesProgressiveViewModel.InitialState?
  private let isPreview: Bool
  private(set) var theme: IOSThemeSnapshot
  private var lastAppliedDraftSignature: DraftSignature?
  private var lastRequestedFocus: (messageID: Int64, revision: Int, requiresExactMessage: Bool)?

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
      theme: theme,
      openAnchor: initialMessages?.openAnchor ?? .latest,
      unreadFetchBoundary: initialMessages?.uncachedUnreadBoundary,
      viewModel: MessagesSectionedViewModel(
        peer: peerId,
        chatId: chatId,
        reversed: true,
        initialState: initialMessages,
        collapsedMaxId: collapsedMaxId
      )
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
        self?.setScrollButtonShown(state.isVisible)
        self?.scrollButton.setCount(state.unreadCount)
      }
      collectionView.onVisibleMessagesChanged = { [weak self] ids in
        guard let navigator = self?.activityNavigator else { return }
        if let ids {
          navigator.noteVisible(messageIds: ids)
        } else {
          navigator.clearVisible()
        }
      }
    }
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    return collectionView
  }()

  /// The message list: the collection view, or the timeline behind its switch.
  private lazy var messageList: any ChatMessageListHosting = {
    guard usesTimeline else { return messagesCollectionView }
    let timeline = TimelineMessagesView(
      peer: peerId, chatId: chatId, spaceId: spaceId, initialState: initialMessages,
      collapsedMaxId: collapsedMaxId, theme: theme, isPreview: isPreview
    )
    timeline.sendAnimationCoordinator = sendAnimationCoordinator
    timeline.isKeyboardVisible = { [weak self] in (self?.keyboardCoordinator?.height ?? 0) > 0 }
    // As for the collection view: the composer gets its focus back after the menu, and a tap that
    // puts the keyboard away waits while it is open.
    timeline.onContextMenuWillDisplay = { [weak self] in
      guard let self else { return }
      restoresComposeFocusAfterContextMenu = restoresComposeFocusAfterContextMenu
        || composeView.textView.isFirstResponder
      keyboardDismissTapGestureRecognizer.isEnabled = false
    }
    timeline.onContextMenuDidEnd = { [weak self] in
      self?.restoreComposeFocusAfterContextMenu()
    }
    timeline.onScrollAffordanceChanged = { [weak self] state in
      self?.setScrollButtonShown(state.isVisible)
      self?.scrollButton.setCount(state.unreadCount)
    }
    timeline.onVisibleMessagesChanged = { [weak self] ids in
      guard let navigator = self?.activityNavigator else { return }
      if let ids { navigator.noteVisible(messageIds: ids) } else { navigator.clearVisible() }
    }
    timeline.list.releaseVelocityFilter = { [weak self] velocity in
      // A drag that moved the keyboard ends there; the list does not also fling.
      self?.keyboardCoordinator?.isInteractive == true ? 0 : velocity
    }
    timeline.translatesAutoresizingMaskIntoConstraints = false
    return timeline
  }()

  // MARK: - Timeline keyboard (one owner)

  private let usesTimeline: Bool
  private var keyboardCoordinator: KeyboardCoordinator?
  private var isApplyingKeyboard = false
  /// Canvas below the composer while the keyboard is up: the system can draw the keyboard a few
  /// frames after the composer starts to rise, and this is what shows in between.
  private lazy var composeSkirt: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    view.isHidden = true
    return view
  }()

  private func installTimelineKeyboard() {
    let coordinator = KeyboardCoordinator(view: self)
    // As the collection view's composer followed the keyboard layout guide: on iPad it rides on an
    // undocked or split keyboard.
    coordinator.followsUndockedKeyboard = UIDevice.current.userInterfaceIdiom == .pad
    coordinator.ridingHeight = { [weak self] in
      guard let self else { return 0 }
      return max(0, bounds.maxY - (keyboardCoordinator?.height ?? 0) - composeContainerView.frame.minY)
    }
    coordinator.allowsInteractiveDismissal = { [weak self] point in
      guard let self else { return false }
      return messageList.bounds.contains(messageList.convert(point, from: nil))
    }
    coordinator.onChange = { [weak self] change in self?.applyKeyboard(change) }
    keyboardCoordinator = coordinator
  }

  /// The composer and the list's bottom inset move here, together, and nowhere else.
  private func applyKeyboard(_ change: KeyboardChange) {
    composeSkirt.backgroundColor = theme.chatCanvas.uiColor
    if keyboardCoordinator?.isFloating == true {
      // A floating keyboard leaves the rows around it in sight.
      composeSkirt.isHidden = true
    } else if change.height > 0 {
      composeSkirt.isHidden = false
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self, keyboardCoordinator?.height == 0 else { return }
        composeSkirt.isHidden = true
      }
    }
    isApplyingKeyboard = true
    composeContainerViewBottomConstraint?.constant = -max(0, change.height - safeAreaInsets.bottom)
    switch change.timing {
      case let .spring(mass, stiffness, damping, _):
        let animator = UIViewPropertyAnimator(
          duration: 0,
          timingParameters: UISpringTimingParameters(
            mass: mass, stiffness: stiffness, damping: damping, initialVelocity: .zero
          )
        )
        animator.addAnimations { self.layoutIfNeeded() }
        animator.startAnimation()
      case .none:
        UIView.performWithoutAnimation { self.layoutIfNeeded() }
      case .curve:
        // Inside a rotation: the layout joins the animation it is called in.
        layoutIfNeeded()
    }
    isApplyingKeyboard = false
    reportComposeArea(change.timing, isInteractive: change.isInteractive)
  }

  private func reportComposeArea(_ timing: TimelineTiming, isInteractive: Bool = false) {
    guard usesTimeline, bounds.height > 0 else { return }
    // A preview has no composer: the list rests on the safe area.
    let composeTop = isPreview ? bounds.maxY - safeAreaInsets.bottom : composeContainerView.frame.minY
    messageList.composeAreaDidChange(
      bottomInset: max(0, bounds.maxY - composeTop), timing: timing, isInteractive: isInteractive
    )
  }

  private lazy var pinnedHeaderView: PinnedMessageHeaderView = {
    let view = PinnedMessageHeaderView(peerId: peerId, chatId: chatId ?? 0, showsVoicePlayback: !isPreview)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onHeightChange = { [weak self] height in
      self?.pinnedHeaderHeightConstraint?.constant = height
      self?.messageList.updatePinnedHeaderHeight(height)
    }
    view.onOpenMessage = { [weak self] messageID in
      self?.messageList.scrollToMessageWhenAvailable(messageID)
    }
    view.onOpenVoiceMessage = { [weak self] target in
      guard let self else { return }
      onOpenVoiceMessage?(target) { [weak self] messageID in
        self?.messageList.scrollToMessageWhenAvailable(messageID, requiresExactMessage: true)
      }
    }
    view.onPlaybackError = { [weak self] error in self?.presentVoicePlaybackError(error) }
    return view
  }()

  private func presentVoicePlaybackError(_ error: String) {
    guard window?.windowScene?.activationState == .foregroundActive,
          !isPreview, canPresentVoicePlaybackError?() == true
    else { return }
    var responder: UIResponder? = self
    while let current = responder {
      if let controller = current as? UIViewController {
        guard controller.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Voice playback failed", message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
          SharedAudioPlayer.shared.clearPlaybackError()
        })
        controller.present(alert, animated: true)
        return
      }
      responder = current.next
    }
  }

  lazy var composeView: ComposeView = {
    let view = ComposeView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.peerId = peerId
    view.chatId = chatId
    view.spaceId = spaceId
    view.sendAnimationCoordinator = sendAnimationCoordinator
    // An agent chat grows into its card inside the setters above. The handler
    // reads this lazy var, which is unset until this closure returns, so
    // subscribing any earlier re-runs the closure until the stack overflows.
    messageList.setInitialComposeHeight(view.composeHeightConstraint.constant)
    view.onHeightChange = { [weak self] newHeight, animation in
      self?.handleComposeViewHeightChange(newHeight, animation: animation)
    }
    view.executeInlineCommand = { [weak self] action in
      guard let self else { return nil }
      switch action {
      case .renameThread:
        guard onRenameThread?() == true else { return nil }
        return .completed
      case .collapseHistory:
        guard let maxID = messageList.highestPositiveMessageId else { return nil }
        try await messageList.collapseHistory(maxID: maxID)
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
  private lazy var mentionButton = BlurCircleButton(
    symbolName: "at",
    tint: ThemeManager.shared.selected.accent,
    accessibilityTitle: "Next Unread Mention"
  )
  private lazy var reactionButton = BlurCircleButton(
    symbolName: "heart.fill",
    tint: .systemPink,
    accessibilityTitle: "Next Unread Reaction"
  )
  private var activityNavigator: ChatActivityNavigator?
  private var mentionButtonBottomConstraint: NSLayoutConstraint?
  private var reactionButtonBottomConstraint: NSLayoutConstraint?
  private var isScrollButtonShown = false
  private var activityState = ChatActivityNavigator.State.empty
  private var isFirstActivityState = true

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
    activityNavigator?.stop()
    sendAnimationCoordinator?.cancelAll()
    NotificationCenter.default.removeObserver(self)
    edgePanGestureRecognizer?.removeTarget(self, action: #selector(handleEdgePan(_:)))
  }

  init(
    peerId: InlineKit.Peer,
    chatId: Int64?,
    spaceId: Int64?,
    collapsedMaxId: Int64? = nil,
    initialMessages: MessagesProgressiveViewModel.InitialState? = nil,
    isPreview: Bool = false,
    theme: IOSThemeSnapshot,
    usesTimeline: Bool = false
  ) {
    self.usesTimeline = usesTimeline
    self.peerId = peerId
    self.chatId = chatId
    self.spaceId = spaceId
    self.collapsedMaxId = collapsedMaxId
    self.initialMessages = initialMessages
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
    sendAnimationCoordinator?.setSourceLayoutView(window == nil ? nil : messageList)
    if !isPreview {
      attachEdgePanHandlerIfNeeded()
      resetComposeToSafeAreaIfKeyboardClosed()
    }
    keyboardCoordinator?.attach(to: window)
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    // A new size (a rotation) can follow the keyboard's last notification: the keyboard is measured again.
    keyboardCoordinator?.viewDidLayout()
    reportComposeBottomOffsetIfNeeded()
    if usesTimeline, !isApplyingKeyboard {
      // The composer grew or the size changed: the list follows inside whatever animation this
      // layout pass belongs to.
      let inherited = UIView.inheritedAnimationDuration
      reportComposeArea(inherited > 0 ? .curve(duration: inherited, c1x: 0.25, c1y: 0.1, c2x: 0.25, c2y: 1) : .none)
    }
  }

  /// On iPad the compose's laid-out position is the only reliable keyboard signal: the
  /// hardware keyboard shortcut bar and undocked keyboards report notification frames that
  /// disagree with it. The list reserves exactly the space the compose occupies.
  private func reportComposeBottomOffsetIfNeeded() {
    guard !usesTimeline, IPadNavigationLane.isEnabled, !isPreview, window != nil, bounds.height > 0 else { return }
    let offset = max(0, bounds.maxY - composeContainerView.frame.maxY)
    guard offset.isFinite else { return }
    messageList.setComposeBottomOffset(offset)
  }

  // MARK: - Bot access

  private var noAccessBar: BotNoAccessBarView?
  private(set) var isBlockedByBotAccess = false

  /// Replaces the composer with a notice in a chat with a bot the viewer
  /// can't message, and brings it back when that stops being true. Only a
  /// known "no" arrives here; an unknown answer keeps the composer.
  func setNoAccessNotice(_ notice: BotNoAccessNotice?, onMessageOwner: @escaping (Int64) -> Void) {
    guard !isPreview else { return }
    guard let notice else {
      guard isBlockedByBotAccess else { return }
      isBlockedByBotAccess = false
      noAccessBar?.isHidden = true
      composeView.isHidden = false
      composeView.isUserInteractionEnabled = true
      return
    }
    let bar = noAccessBar ?? makeNoAccessBar()
    bar.update(notice, onMessageOwner: onMessageOwner)
    guard !isBlockedByBotAccess else { return }
    isBlockedByBotAccess = true
    // Typing must not land in a composer nobody can see.
    composeView.textView.resignFirstResponder()
    composeView.isHidden = true
    composeView.isUserInteractionEnabled = false
    bar.isHidden = false
  }

  private func makeNoAccessBar() -> BotNoAccessBarView {
    let bar = BotNoAccessBarView()
    bar.isHidden = true
    insertSubview(bar, aboveSubview: composeView)
    // The composer keeps its place in the layout, so the list, the keyboard
    // guide and the floating buttons need no second set of rules.
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: composeView.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: composeView.trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: composeView.bottomAnchor),
      bar.topAnchor.constraint(greaterThanOrEqualTo: composeView.topAnchor),
    ])
    noAccessBar = bar
    return bar
  }

  func loadDraftIfNeeded(_ draftMessage: DraftMessage?) {
    guard !isPreview, !isBlockedByBotAccess else { return }
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

  func focusMessage(_ messageID: Int64?, requestRevision: Int, requiresExactMessage: Bool) {
    guard let messageID else {
      // An unchanged ordinary chat route does not own the pill's pending jump.
      guard lastRequestedFocus != nil else { return }
      lastRequestedFocus = nil
      messageList.cancelPendingMessageFocus()
      return
    }
    guard lastRequestedFocus?.messageID != messageID || lastRequestedFocus?.revision != requestRevision
      || lastRequestedFocus?.requiresExactMessage != requiresExactMessage else { return }
    lastRequestedFocus = (messageID, requestRevision, requiresExactMessage)
    messageList.scrollToMessageWhenAvailable(messageID, requiresExactMessage: requiresExactMessage)
  }

  #if DEBUG
  /// The harness's stand-in for a DM peer's focus status: the line under the newest message.
  func debugSetStatusNotice(_ text: String?) {
    (messageList as? TimelineMessagesView)?.viewModel.rowFeed.setStatusNotice(text)
  }
  #endif

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    guard self.collapsedMaxId != collapsedMaxId else { return }
    self.collapsedMaxId = collapsedMaxId
    messageList.setCollapsedMaxId(collapsedMaxId)
  }

  func applyTheme(_ theme: IOSThemeSnapshot) {
    guard self.theme != theme else { return }
    self.theme = theme
    backgroundColor = theme.chatCanvas.uiColor
    tintColor = theme.primary.uiColor
    composeView.tintColor = theme.primary.uiColor
    pinnedHeaderView.tintColor = theme.primary.uiColor
    scrollButton.tintColor = theme.primary.uiColor
    messageList.applyTheme(theme)
  }

  private var mentionCompletionHeightConstraint: NSLayoutConstraint!

  private func setupViews() {
    backgroundColor = theme.chatCanvas.uiColor
    tintColor = theme.primary.uiColor

    addSubview(messageList)
    sendAnimationCoordinator?.setSourceLayoutView(messageList)
    addSubview(pinnedHeaderView)

    pinnedHeaderHeightConstraint = pinnedHeaderView.heightAnchor.constraint(equalToConstant: pinnedHeaderView.displayedHeight)
    let commonConstraints = [
      messageList.topAnchor.constraint(equalTo: topAnchor),
      messageList.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      messageList.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      messageList.bottomAnchor.constraint(equalTo: bottomAnchor),

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

    messageList.addGestureRecognizer(keyboardDismissTapGestureRecognizer)
    addSubview(composeContainerView)
    composeContainerView.addSubview(borderView)
    addSubview(mentionCompletionViewWrapper)
    addSubview(composeView)
    addSubview(scrollButton)
    scrollButton.onTap = { [weak self] in
      self?.messageList.scrollToBottom()
    }
    addSubview(mentionButton)
    mentionButton.onTap = { [weak self] in
      self?.jumpToNextActivity()
    }
    mentionButton.setMenu(UIMenu(children: [
      UIAction(title: "Mark All Mentions as Read", image: UIImage(systemName: "checkmark.message")) { [weak self] _ in
        self?.activityNavigator?.markAllMentionsRead()
      },
    ]))
    addSubview(reactionButton)
    reactionButton.onTap = { [weak self] in
      self?.jumpToNextReaction()
    }
    reactionButton.setMenu(UIMenu(children: [
      UIAction(title: "Mark All Reactions as Seen", image: UIImage(systemName: "checkmark")) { [weak self] _ in
        self?.activityNavigator?.markAllReactionsRead()
      },
    ]))

    if usesTimeline {
      installTimelineKeyboard()
      insertSubview(composeSkirt, belowSubview: composeContainerView)
      NSLayoutConstraint.activate([
        composeSkirt.topAnchor.constraint(equalTo: composeContainerView.bottomAnchor),
        composeSkirt.leadingAnchor.constraint(equalTo: leadingAnchor),
        composeSkirt.trailingAnchor.constraint(equalTo: trailingAnchor),
        composeSkirt.heightAnchor.constraint(equalToConstant: 700),
      ])
    } else if usesIOS27KeyboardWorkaround {
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

        // Mirrors the compose plus button: the same glass circle, its trailing edge on the compose
        // pill's, and the gap above compose equal to the gap between stacked buttons.
        scrollButton.trailingAnchor.constraint(
          equalTo: composeTrailingAnchor,
          constant: -(ComposeView.textViewHorizantalMargin * 2 - BlurCircleButton.hitOutset)
        ),
        scrollButton.bottomAnchor.constraint(
          equalTo: composeView.topAnchor,
          constant: -(BlurCircleButton.stackSpacing - BlurCircleButton.hitOutset)
        ),

        mentionButton.centerXAnchor.constraint(equalTo: scrollButton.centerXAnchor),
        reactionButton.centerXAnchor.constraint(equalTo: scrollButton.centerXAnchor),
      ]
    )
    // Stacked from the bottom: scroll-to-bottom, @, ♥. Hidden buttons take no slot.
    mentionButtonBottomConstraint = mentionButton.bottomAnchor.constraint(equalTo: scrollButton.bottomAnchor)
    reactionButtonBottomConstraint = reactionButton.bottomAnchor.constraint(equalTo: scrollButton.bottomAnchor)
    mentionButtonBottomConstraint?.isActive = true
    reactionButtonBottomConstraint?.isActive = true
    startActivityNavigator()
  }

  private static let floatingButtonStep = BlurCircleButton.visualSize + BlurCircleButton.stackSpacing

  private func layoutFloatingButtons(animated: Bool) {
    let mentionSlot = isScrollButtonShown ? 1 : 0
    let reactionSlot = mentionSlot + (activityState.mentionsCount > 0 ? 1 : 0)
    mentionButtonBottomConstraint?.constant = -CGFloat(mentionSlot) * Self.floatingButtonStep
    reactionButtonBottomConstraint?.constant = -CGFloat(reactionSlot) * Self.floatingButtonStep
    guard animated, window != nil else { return }
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22) {
      self.layoutIfNeeded()
    }
  }

  // MARK: - Unread mentions and replies

  private func startActivityNavigator() {
    guard activityNavigator == nil, !isPreview, let chatId, chatId > 0 else { return }
    let navigator = ChatActivityNavigator(peerId: peerId, chatId: chatId)
    navigator.onChange = { [weak self] state in
      self?.applyActivityState(state)
    }
    activityNavigator = navigator
    navigator.start()
    applyActivityState(navigator.state)
  }

  private func applyActivityState(_ state: ChatActivityNavigator.State) {
    messageList.setUnreadState(state)
    // Read-marker updates arrive often while scrolling; only @ and ♥ changes move the stack.
    guard !state.hasSameActivity(as: activityState) || isFirstActivityState else { return }
    isFirstActivityState = false
    activityState = state
    mentionButton.setCount(state.mentionsCount)
    mentionButton.setVisible(state.mentionsCount > 0)
    reactionButton.setCount(state.reactionsCount)
    reactionButton.setVisible(state.reactionsCount > 0)
    layoutFloatingButtons(animated: true)
  }

  private func setScrollButtonShown(_ shown: Bool) {
    scrollButton.setVisible(shown)
    guard isScrollButtonShown != shown else { return }
    isScrollButtonShown = shown
    layoutFloatingButtons(animated: true)
  }

  private func jumpToNextReaction() {
    guard let navigator = activityNavigator else { return }
    Task { @MainActor [weak self] in
      guard let messageId = await navigator.nextReactionMessageId(), let self else { return }
      self.messageList.scrollToMessageWhenAvailable(messageId)
    }
  }

  private func jumpToNextActivity() {
    guard let navigator = activityNavigator else { return }
    Task { @MainActor [weak self] in
      guard let messageId = await navigator.nextMessageId(), let self else { return }
      self.messageList.scrollToMessageWhenAvailable(messageId)
    }
  }

  private func setupObservers() {
    if usesTimeline {
      // The keyboard coordinator is the only keyboard observer of this screen.
    } else if usesIOS27KeyboardWorkaround {
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

    guard var inset = keyboardOverlap(with: keyboardFrame) else {
      if !isComposeFocused {
        animateComposeSafeAreaReset(animated: animated, notification: notification)
      }
      return
    }

    // iPad: sending or reloading input views makes the hardware keyboard shortcut bar
    // briefly report a hidden keyboard while it stays on screen. The tracking accessory
    // has not moved, so its display link never corrects a reset. Trust what it measures.
    if isComposeFocused, inset <= 0.5, IPadNavigationLane.isEnabled,
       let keyboardTop = keyboardTrackingAccessoryView.keyboardTop(in: self),
       let measuredInset = normalizedKeyboardInset(fromKeyboardTop: keyboardTop),
       measuredInset > 0.5
    {
      inset = measuredInset
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
    // Keyboard notification frames are in screen coordinates. Converting from the window
    // (`from: nil`) only matches full screen; an iPad window offset on screen read the
    // keyboard too low and parked the compose under the hardware keyboard shortcut bar.
    let keyboardFrameInView = if let screen = window?.windowScene?.screen {
      convert(keyboardFrame, from: screen.coordinateSpace)
    } else {
      convert(keyboardFrame, from: nil)
    }
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
    guard window != nil, !usesTimeline else { return }
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
      messageList.deferComposeInsetForPendingSendAnimation(composeHeight: newHeight)
    } else {
      messageList.updateComposeInset(
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
    if usesTimeline {
      // The system carries the keyboard with the popping screen, posts a hide when the swipe
      // begins and brings the keyboard back without animation on cancel. Following any of that
      // is the glitch: keep first responder, leave the composer where it is.
      switch gesture.state {
        case .began:
          keyboardCoordinator?.suspend()
        case .ended, .cancelled, .failed:
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.keyboardCoordinator?.resume()
          }
        default:
          break
      }
      return
    }
    // Dismiss keyboard as soon as back-swipe begins and guard against auto-refocus after cancel.
    switch gesture.state {
    case .began:
      messageList.cancelContextMenuKeyboardRestoration()
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
    guard !messageList.isContextMenuInteractionActive,
          composeView.textView.isFirstResponder else { return }
    messageList.cancelContextMenuKeyboardRestoration()
    composeView.textView.resignFirstResponder()
  }

  private func restoreComposeFocusAfterContextMenu() {
    // An emoji selection can finish the menu before its overlay sheet closes.
    // Keep the pending focus request until the picker returns the key window.
    guard !messageList.isReactionPickerPresented else { return }
    let shouldRestore = restoresComposeFocusAfterContextMenu
    restoresComposeFocusAfterContextMenu = false
    keyboardDismissTapGestureRecognizer.isEnabled = true

    // Actions that navigate or present a sheet own focus from this point on.
    guard shouldRestore,
          window?.isKeyWindow == true,
          composeView.textView.isEditable,
          let controller = findViewController(),
          !controller.isBeingDismissed,
          !controller.isMovingFromParent,
          controller.presentedViewController == nil,
          controller.navigationController?.presentedViewController == nil,
          controller.navigationController.map({ $0.topViewController === controller }) ?? true
    else {
      messageList.cancelContextMenuKeyboardRestoration()
      return
    }
    // Keyboard notifications can arrive after the menu animator completes.
    messageList.preserveContextMenuViewportForKeyboardRestoration()
    // UIKit can retain focus while temporarily hiding the keyboard for its menu.
    // Restoring the viewport is still necessary when focus itself never changed.
    guard !composeView.textView.isFirstResponder else { return }
    if !composeView.textView.becomeFirstResponder() {
      messageList.cancelContextMenuKeyboardRestoration()
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
    guard !messageList.isContextMenuInteractionActive else { return false }

    // A date tap owns navigation. Dismissing the keyboard on the same tap can
    // change the list's insets and cancel the scroll started by the button.
    var touchedView = touch.view
    while let view = touchedView {
      if view is DateSeparatorView || view is TimelineDatePill {
        return false
      }
      if let cell = view as? MessageCollectionViewCell,
         cell.isMessageActionsButton(at: touch.location(in: cell)) {
        return false
      }
      if view is TimelineMessageActionsButton {
        return false
      }
      if view === messageList {
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
  @Environment(Router.self) private var router
  let peerId: InlineKit.Peer
  let chatId: Int64?
  let spaceId: Int64?
  let draftMessage: DraftMessage?
  let focusMessageID: Int64?
  let focusMessageExactly: Bool
  let focusRequestRevision: Int
  let collapsedMaxId: Int64?
  var initialMessages: MessagesProgressiveViewModel.InitialState? = nil
  let isPreview: Bool
  let theme: IOSThemeSnapshot
  var onRenameThread: (() -> Bool)? = nil
  /// Set for a chat with a bot the viewer can't message.
  var noAccessNotice: BotNoAccessNotice? = nil
  var onMessageBotOwner: (Int64) -> Void = { _ in }
  /// The new message list, read when the chat is built.
  var usesTimeline = TimelineFeature.isEnabled(allowsOverride: SettingsBuildAudience.showsDebugTools)

  func makeUIView(context _: Context) -> ChatContainerView {
    let view = ChatContainerView(
      peerId: peerId,
      chatId: chatId,
      spaceId: spaceId,
      collapsedMaxId: collapsedMaxId,
      initialMessages: initialMessages,
      isPreview: isPreview,
      theme: theme,
      usesTimeline: usesTimeline
    )
    view.onRenameThread = isPreview ? nil : onRenameThread
    configureVoicePlaybackNavigation(view)
    if !isPreview {
      // Before the draft: a chat that takes no messages restores none.
      view.setNoAccessNotice(noAccessNotice, onMessageOwner: onMessageBotOwner)
      view.loadDraftIfNeeded(draftMessage)
      view.focusMessage(
        focusMessageID, requestRevision: focusRequestRevision, requiresExactMessage: focusMessageExactly
      )
    }

    return view
  }

  func updateUIView(_ view: ChatContainerView, context _: Context) {
    view.onRenameThread = isPreview ? nil : onRenameThread
    configureVoicePlaybackNavigation(view)
    view.applyTheme(theme)
    view.setCollapsedMaxId(collapsedMaxId)
    if !isPreview {
      view.setNoAccessNotice(noAccessNotice, onMessageOwner: onMessageBotOwner)
      view.loadDraftIfNeeded(draftMessage)
      view.focusMessage(
        focusMessageID, requestRevision: focusRequestRevision, requiresExactMessage: focusMessageExactly
      )
    }
  }

  private func configureVoicePlaybackNavigation(_ view: ChatContainerView) {
    view.canPresentVoicePlaybackError = {
      router.presentedSheet == nil && router.selectedTabPath.last?.chatPeer == peerId
    }
    view.onOpenVoiceMessage = { target, scrollToMessage in
      VoicePlaybackNavigation.open(
        target, router: router, currentPeer: peerId, currentChatID: chatId,
        scrollToMessage: scrollToMessage
      )
    }
  }
}

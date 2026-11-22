import Auth
import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineIOSUI
import InlineTheme
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import Translation
import UIKit

/// A chat on a navigation stack: hosts the UIKit `ChatContainerView` (message list + compose),
/// owns the toolbar, chat loading, message-update activation and cross-chat navigation.
/// Replaces the SwiftUI `ChatView`.
///
/// iOS 26+: the navigation bar is Liquid Glass over the list with a soft scroll edge effect.
/// Before 26: the system default bar background.
@MainActor
final class ChatViewController: UIViewController {
  struct Options {
    var contextSpaceID: Int64?
    var focusMessageID: Int64?
    var focusMessageExactly = false
    var autoCleanupUntitledEmptyThreadOnBack = false
    var isPreview = false
  }

  let peer: Peer
  private let options: Options
  private unowned let shell: MainShellController
  private let viewModel: FullChatViewModel
  private var container: ChatContainerView?
  private var initialMessages: MessagesProgressiveViewModel.InitialState?
  private var initialMessagesReady: Bool
  private var activeChatToken: MessagesPublisher.ActiveChatToken?
  private var isVisible = false
  private var didAttemptCleanup = false
  private var cancellables: Set<AnyCancellable> = []
  private let titleView = ChatTitleView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var unavailableView: EmptyStateView?
  private var loadTask: Task<Void, Never>?
  private var headerView: UIView?
  private var headerHeight: NSLayoutConstraint?
  private var headerExtra: CGFloat = 12

  private var router: Router { shell.router }

  init(peer: Peer, shell: MainShellController, options: Options = Options()) {
    self.peer = peer
    self.shell = shell
    self.options = options
    viewModel = FullChatViewModel(db: AppDatabase.shared, peer: peer)
    let preparation = ChatOpenPreparation.shared
    if let state = preparation.readyState(for: peer) {
      initialMessages = state
      initialMessagesReady = true
    } else {
      initialMessages = nil
      // Nothing read ahead (notification, deep link, restoration): the list reads its window
      // synchronously rather than showing an empty chat.
      initialMessagesReady = !preparation.isPreparing(peer: peer)
    }
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = !options.isPreview
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = ThemeManager.shared.selected.backgroundColor
    navigationItem.titleView = titleView
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.backButtonDisplayMode = .minimal
    navigationItem.compatSetStyle(.editor)
    configureBarAppearance()
    installHeader()
    navigationItem.rightBarButtonItems = [moreItem()]

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    bindViewModel()
    bindNotifications()
    titleView.bind(peer: peer, viewModel: viewModel)
    titleView.onTap = { [weak self] in self?.openChatInfo() }

    // Synchronous first frame when the chat and its first window are local.
    buildContainerIfReady()
    if !initialMessagesReady {
      Task { [weak self, peer] in
        let state = await ChatOpenPreparation.shared.state(for: peer)
        guard let self else { return }
        initialMessages = state
        initialMessagesReady = true
        buildContainerIfReady()
      }
    }
    loadChat()
    ExperimentalHomeNavigationPerformance.completeChatOpen(peer: peer)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    guard !options.isPreview else { return }
    isVisible = true
    updateMessageActivation()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard !options.isPreview else { return }
    isVisible = false
    updateMessageActivation()
    scheduleUntitledThreadCleanupIfNeeded()
  }

  deinit {
    loadTask?.cancel()
  }

  /// The bar is transparent on every system; the chat draws its own header behind it, as the
  /// SwiftUI chat did: a soft variable blur, or on iOS 27 the "Hard" material when chosen.
  /// (The message list is inverted, so system scroll edge tracking can't drive it.)
  private func configureBarAppearance() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance
    navigationItem.compactAppearance = appearance
  }

  private func installHeader() {
    guard !options.isPreview else { return }
    let header: UIView
    let mode = ChatToolbarBackgroundMode(rawValue: UserDefaults.standard.string(forKey: ChatToolbarBackgroundMode.key) ?? "")
      ?? ChatToolbarBackgroundMode.initialValue
    if #available(iOS 27.0, *), CompatRuntime.allows(.iOS27), mode == .hard {
      header = ChatToolbarHardBackgroundMaterialView()
      headerExtra = 0
    } else {
      header = ChatSoftHeaderView()
      headerExtra = 12
    }
    header.isUserInteractionEnabled = false
    header.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header)
    headerHeight = header.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.topAnchor),
      header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      headerHeight!,
    ])
    headerView = header
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    headerHeight?.constant = view.safeAreaInsets.top + headerExtra
    if let headerView, headerView.superview === view { view.bringSubviewToFront(headerView) }
  }

  // MARK: Content

  private func buildContainerIfReady() {
    guard container == nil, initialMessagesReady, let chat = viewModel.chat else { return }
    let style: ThemeAppearanceVariant = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    let container = ChatContainerView(
      peerId: peer,
      chatId: chat.id,
      spaceId: chat.spaceId,
      collapsedMaxId: viewModel.chatItem?.dialog.collapsedMaxId,
      initialMessages: initialMessages,
      isPreview: options.isPreview,
      theme: ThemeManager.shared.snapshot(variant: style),
      usesTimeline: TimelineFeature.isEnabled(allowsOverride: SettingsBuildAudience.showsDebugTools)
    )
    container.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(container, at: 0)
    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: view.topAnchor),
      container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    self.container = container
    configureContainerCallbacks(container)
    if !options.isPreview {
      container.setNoAccessNotice(botNoAccessNotice, onMessageOwner: { [weak self] ownerID in
        self?.router.openPrimaryDestination(.chat(peer: .user(id: ownerID)))
      })
      container.loadDraftIfNeeded(viewModel.chatItem?.dialog.draftMessage)
      container.focusMessage(
        options.focusMessageID,
        requestRevision: router.presentationResetRevision,
        requiresExactMessage: options.focusMessageExactly
      )
    }
    spinner.stopAnimating()
    unavailableView?.removeFromSuperview()
    unavailableView = nil
  }

  private func configureContainerCallbacks(_ container: ChatContainerView) {
    container.onRenameThread = options.isPreview ? nil : { [weak self] in
      guard let self else { return false }
      guard peer.asThreadId() != nil else {
        ToastManager.shared.showToast("Only threads can be renamed.", type: .error)
        return false
      }
      guard let item = viewModel.chatItem, item.chat?.canUpdateInfo != false else {
        ToastManager.shared.showToast("You can’t rename this thread.", type: .error)
        return false
      }
      shell.presentChatInfo(item, from: self, editing: true)
      return true
    }
    container.canPresentVoicePlaybackError = { [weak self] in
      guard let self else { return false }
      return router.presentedSheet == nil && router.selectedTabPath.last?.chatPeer == peer
    }
    container.onOpenVoiceMessage = { [weak self] target, scrollToMessage in
      guard let self else { return }
      VoicePlaybackNavigation.open(
        target, router: router, currentPeer: peer, currentChatID: viewModel.chat?.id,
        scrollToMessage: scrollToMessage
      )
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
    applyTheme()
  }

  private func applyTheme() {
    let style: ThemeAppearanceVariant = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    container?.applyTheme(ThemeManager.shared.snapshot(variant: style))
    view.backgroundColor = ThemeManager.shared.selected.backgroundColor
  }

  /// Chat with a bot the viewer can't message: the notice replaces the composer.
  private var botNoAccessNotice: BotNoAccessNotice? {
    guard !options.isPreview, case .user = peer, let bot = viewModel.peerUser, bot.bot == true else { return nil }
    let access = AgentGrantStore.shared.access(botUserID: bot.id)
    let owner = access.flatMap { ObjectCache.shared.getCachedUser(id: $0.ownerUserID)?.user }
    return BotNoAccessNotice.make(bot: bot, access: access, owner: owner)
  }

  // MARK: Loading

  private func loadChat() {
    if viewModel.chat != nil {
      if !options.isPreview { viewModel.refetchHistoryOnly() }
      return
    }
    spinner.startAnimating()
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let chat = try await viewModel.ensureChat()
        guard !Task.isCancelled else { return }
        if chat != nil || viewModel.chat != nil {
          if !options.isPreview { viewModel.refetchHistoryOnly() }
          buildContainerIfReady()
        } else {
          showUnavailable()
        }
      } catch {
        guard !Task.isCancelled else { return }
        if viewModel.chat != nil { buildContainerIfReady() } else { showUnavailable() }
      }
    }
  }

  /// A calm empty state: the usual reason is a private thread someone linked before adding you.
  private func showUnavailable() {
    spinner.stopAnimating()
    guard unavailableView == nil, container == nil else { return }
    let empty = EmptyStateView(
      systemImage: peer.isThread ? "lock" : "bubble.left",
      title: peer.isThread ? String(localized: "Private Thread") : String(localized: "Chat Unavailable"),
      message: peer.isThread
        ? String(localized: "You don't have access to this thread. Ask someone in it to add you.")
        : String(localized: "This conversation isn't available to you."),
      actionTitle: String(localized: "Check Again")
    ) { [weak self] in
      self?.unavailableView?.removeFromSuperview()
      self?.unavailableView = nil
      self?.loadChat()
    }
    empty.backgroundColor = .systemBackground
    empty.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(empty)
    NSLayoutConstraint.activate([
      empty.topAnchor.constraint(equalTo: view.topAnchor),
      empty.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      empty.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      empty.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    unavailableView = empty
  }

  private func bindViewModel() {
    viewModel.chatItemPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] item in
        guard let self else { return }
        buildContainerIfReady()
        guard let container, !options.isPreview else { return }
        container.setCollapsedMaxId(item?.dialog.collapsedMaxId)
        container.loadDraftIfNeeded(item?.dialog.draftMessage)
        container.setNoAccessNotice(botNoAccessNotice, onMessageOwner: { [weak self] ownerID in
          self?.router.openPrimaryDestination(.chat(peer: .user(id: ownerID)))
        })
      }
      .store(in: &cancellables)

    ThemeManager.shared.$selectedPreset
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.applyTheme() }
      .store(in: &cancellables)

    if let bot = viewModel.peerUser, bot.bot == true, !options.isPreview {
      AgentGrantStore.shared.refresh(botUserID: bot.id)
    }
  }

  // MARK: Message updates

  private func updateMessageActivation() {
    let sceneActive = view.window?.windowScene?.activationState == .foregroundActive
      || UIApplication.shared.applicationState == .active
    if !options.isPreview, isVisible, sceneActive {
      if let token = activeChatToken, token.peer == peer { return }
      if let token = activeChatToken { MessagesPublisher.shared.deactivateChat(token) }
      activeChatToken = MessagesPublisher.shared.activateChat(peer: peer)
    } else if let token = activeChatToken {
      MessagesPublisher.shared.deactivateChat(token)
      activeChatToken = nil
    }
  }

  // MARK: Notifications

  private var canHandleGlobalNavigation: Bool {
    guard !options.isPreview else { return false }
    // Only the chat on top of the selected tab handles links and mentions.
    return isVisible && router.selectedTabPath.last?.chatPeer == peer
  }

  private func bindNotifications() {
    let center = NotificationCenter.default
    func on(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
      center.publisher(for: name)
        .receive(on: DispatchQueue.main)
        .sink { notification in handler(notification) }
        .store(in: &cancellables)
    }

    on(UIApplication.didBecomeActiveNotification) { [weak self] _ in
      guard let self else { return }
      updateMessageActivation()
      if !options.isPreview, viewModel.chat != nil { viewModel.refetchHistoryOnly() }
    }
    on(UIApplication.willResignActiveNotification) { [weak self] _ in self?.updateMessageActivation() }

    on(Notification.Name("chatDeletedNotification")) { [weak self] notification in
      guard let self, !options.isPreview else { return }
      if let chatId = notification.userInfo?["chatId"] as? Int64, chatId == viewModel.chat?.id ?? 0 {
        router.pop()
      }
    }
    on(Notification.Name("MentionTapped")) { [weak self] notification in
      guard let self, canHandleGlobalNavigation, let userId = notification.userInfo?["userId"] as? Int64 else { return }
      router.openPrimaryDestination(.chat(peer: .user(id: userId)))
    }
    on(Notification.Name("NavigateToUser")) { [weak self] notification in
      guard let self, canHandleGlobalNavigation, let userId = notification.userInfo?["userId"] as? Int64 else { return }
      openUserFromAvatar(userId)
    }
    on(Notification.Name("NavigateToForwardedMessage")) { [weak self] notification in
      self?.handleNavigateToForwardedMessage(notification)
    }
    for name in [Notification.Name("NavigateToForwardDestination"), .navigateToThreadLink, .navigateToReplyThread] {
      on(name) { [weak self] notification in
        guard let self, canHandleGlobalNavigation, let target = Self.targetPeer(notification), target != peer else { return }
        router.openPrimaryDestination(.chat(peer: target))
      }
    }
    on(.userGroupMentionTapped) { [weak self] notification in
      guard let self, !options.isPreview,
            var target = notification.userInfo?["target"] as? UserGroupMentionTarget
      else { return }
      if target.spaceId == nil { target.spaceId = options.contextSpaceID ?? viewModel.chat?.spaceId }
      shell.presentUserGroupMembers(target, from: self)
    }
    on(.botAgentMentionTapped) { [weak self] notification in
      guard let self, !options.isPreview,
            let target = notification.userInfo?["target"] as? BotAgentMentionTarget, target.peer == peer
      else { return }
      shell.presentBotAgentProfile(target, from: self)
    }
    on(.mediaSendFailed) { [weak self] notification in
      guard let self, !options.isPreview,
            let chatId = notification.userInfo?["chatId"] as? Int64, chatId == viewModel.chat?.id
      else { return }
      let message = notification.userInfo?["message"] as? String ?? "Couldn't send attachment."
      ToastManager.shared.showToast(message, type: .error, systemImage: "exclamationmark.triangle.fill")
    }
  }

  private static func targetPeer(_ notification: Notification) -> Peer? {
    if let userId = notification.userInfo?["peerUserId"] as? Int64 { return .user(id: userId) }
    if let threadId = notification.userInfo?["peerThreadId"] as? Int64 { return .thread(id: threadId) }
    return nil
  }

  /// A bot's avatar opens its chat info; people's avatars open their chat.
  private func openUserFromAvatar(_ userId: Int64) {
    if let item = FullChatViewModel.cachedChatItem(peer: .user(id: userId)), item.userInfo?.user.bot == true {
      shell.presentChatInfo(item, from: self, editing: false)
      return
    }
    router.openPrimaryDestination(.chat(peer: .user(id: userId)))
  }

  private func handleNavigateToForwardedMessage(_ notification: Notification) {
    guard canHandleGlobalNavigation,
          let messageId = notification.userInfo?["messageId"] as? Int64,
          let target = Self.targetPeer(notification)
    else { return }
    if target == peer, let chatId = viewModel.chat?.id {
      postScrollToMessage(messageId, chatId: chatId)
      return
    }
    Task { [weak self] in
      guard let self else { return }
      if let chat = try? Chat.getByPeerId(peerId: target) {
        router.push(.chat(peer: target))
        postScrollToMessage(messageId, chatId: chat.id, delay: 0.25)
        return
      }
      do {
        _ = try await Api.realtime.send(.getChat(peer: target))
      } catch {
        Log.shared.error("NavigateToForwardedMessage: getChat failed for peer \(target)", error: error)
      }
      if let chat = try? Chat.getByPeerId(peerId: target) {
        router.push(.chat(peer: target))
        postScrollToMessage(messageId, chatId: chat.id, delay: 0.25)
        return
      }
      ToastManager.shared.showToast("You don't have access to that chat", type: .error, systemImage: "exclamationmark.triangle")
    }
  }

  private func postScrollToMessage(_ messageId: Int64, chatId: Int64, delay: TimeInterval = 0) {
    let post = {
      NotificationCenter.default.post(
        name: Notification.Name("ScrollToRepliedMessage"),
        object: nil,
        userInfo: ["repliedToMessageId": messageId, "chatId": chatId]
      )
    }
    if delay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: post)
    } else {
      post()
    }
  }

  // MARK: Untitled thread cleanup

  private func scheduleUntitledThreadCleanupIfNeeded() {
    guard options.autoCleanupUntitledEmptyThreadOnBack, case .thread = peer, !didAttemptCleanup else { return }
    Task { [weak self] in
      await Task.yield()
      guard let self, !chatRouteStillPresent else { return }
      didAttemptCleanup = true
      do {
        _ = try await shell.data.deleteThreadIfUntitledAndEmpty(peerId: peer)
      } catch {
        Log.shared.error("Failed to cleanup untitled empty thread on exit", error: error)
      }
    }
  }

  private var chatRouteStillPresent: Bool {
    AppTab.allCases.contains { tab in
      router[tab].contains { $0.chatPeer == peer }
    }
  }

  // MARK: Toolbar

  private func openChatInfo() {
    guard !options.isPreview, let item = viewModel.chatItem else { return }
    shell.presentChatInfo(item, from: self, editing: false)
  }

  private func moreItem() -> UIBarButtonItem {
    let menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.moreMenuElements() ?? [])
      },
    ])
    let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
    item.accessibilityLabel = String(localized: "More")
    return item
  }

  private func moreMenuElements() -> [UIMenuElement] {
    let chat = viewModel.chat
    let dialog = viewModel.chatItem?.dialog
    var primary: [UIMenuElement] = []

    let translationEnabled = TranslationState.shared.isTranslationEnabled(for: peer)
    primary.append(UIAction(
      title: translationEnabled ? String(localized: "Show Original") : String(localized: "Translate"),
      image: UIImage(systemName: "translate")
    ) { [weak self] _ in
      guard let self else { return }
      TranslationState.shared.setTranslationEnabled(!translationEnabled, for: peer)
    })
    primary.append(UIAction(title: String(localized: "Chat Info"), image: UIImage(systemName: "info.circle")) {
      [weak self] _ in self?.openChatInfo()
    })
    if dialog?.open != true || dialog?.archived == true || dialog?.chatListHidden == true {
      primary.append(UIAction(
        title: String(localized: "Open"),
        subtitle: String(localized: "Add to Open Chats"),
        image: UIImage(systemName: "tray.and.arrow.down")
      ) { [peer] _ in
        Task {
          do {
            guard try await InboxMembershipService.shared.open(peer: peer) else { return }
            ToastManager.shared.showToast("Now in Open Chats", type: .success, systemImage: "bubble.left.fill")
          } catch {
            ToastManager.shared.showToast("Couldn’t open chat", type: .error, systemImage: "exclamationmark.triangle.fill")
          }
        }
      })
    }
    primary.append(notificationsMenu(selection: dialog?.notificationSelection ?? .global))

    var links: [UIMenuElement] = []
    if let chatId = chat?.id {
      links.append(UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "link")) { _ in
        guard let url = InlineDeepLink.chat(id: chatId).webURL else { return }
        UIPasteboard.general.string = url.absoluteString
        ToastManager.shared.showToast("Copied link", type: .success, systemImage: "link")
      })
      links.append(UIAction(title: String(localized: "Copy Deep Link"), image: UIImage(systemName: "arrow.up.forward.app")) { _ in
        guard let url = InlineDeepLink.chat(id: chatId).url else { return }
        UIPasteboard.general.string = url.absoluteString
        ToastManager.shared.showToast("Copied deep link", type: .success, systemImage: "link")
      })
    }

    var state: [UIMenuElement] = []
    if peer.asUserId() == nil, let dialog {
      let follow = dialog.followMode != .following
      state.append(UIAction(
        title: follow ? String(localized: "Follow") : String(localized: "Unfollow"),
        image: UIImage(systemName: follow ? "eye" : "eye.slash")
      ) { [peer] _ in
        Task {
          _ = try? await Api.realtime.send(.updateDialogFollowMode(peerId: peer, selection: follow ? .following : .unfollowed))
          ToastManager.shared.showToast(
            follow ? "Following" : "Unfollowed",
            description: follow ? "New messages will appear in Open Chats." : "Only mentions and replies can bring this chat back.",
            type: .success,
            systemImage: follow ? "eye.fill" : "eye.slash.fill"
          )
        }
      })
    }
    if let dialog {
      let nextPinned: Bool? = dialog.pinned == true
        ? false
        : (dialog.open && dialog.archived != true && dialog.chatListHidden != true ? true : nil)
      if let nextPinned {
        state.append(UIAction(
          title: nextPinned ? String(localized: "Pin") : String(localized: "Unpin"),
          image: UIImage(systemName: nextPinned ? "pin" : "pin.slash")
        ) { [peer] _ in
          Task { _ = try? await Api.realtime.send(.updateDialogOrder(peerId: peer, pinned: nextPinned)) }
        })
      }
    }

    return [
      UIMenu(options: .displayInline, children: primary),
      UIMenu(options: .displayInline, children: links),
      UIMenu(options: .displayInline, children: state),
    ]
  }

  private func notificationsMenu(selection: DialogNotificationSettingSelection) -> UIMenu {
    let globalMode = INUserSettings.current.notification.mode
    let option: (DialogNotificationSettingSelection) -> UIAction = { [peer] option in
      UIAction(
        title: DialogNotificationSettingsPresentation.title(for: option, globalMode: globalMode),
        state: option == selection ? .on : .off
      ) { _ in
        guard option != selection else { return }
        Task {
          do {
            _ = try await Api.realtime.send(.updateDialogNotificationSettings(peerId: peer, selection: option))
          } catch {
            ToastManager.shared.showToast("Could not update notifications", type: .error, systemImage: "exclamationmark.triangle")
          }
        }
      }
    }
    return UIMenu(
      title: String(localized: "Notifications"),
      image: UIImage(systemName: DialogNotificationSettingsPresentation.iconName(for: selection, globalMode: globalMode)),
      children: [
        UIMenu(title: DialogNotificationSettingsPresentation.globalDescription, options: .displayInline, children: [option(.global)]),
        UIMenu(
          title: String(localized: "Overrides for this chat"),
          options: .displayInline,
          children: DialogNotificationSettingsPresentation.overrideOptions.map(option)
        ),
      ]
    )
  }
}

/// Soft header behind the transparent bar: variable blur over a background-to-clear gradient.
private final class ChatSoftHeaderView: UIView {
  private let gradient = CAGradientLayer()
  private let blur = VariableBlurUIView(maxBlurRadius: 6)

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.addSublayer(gradient)
    blur.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blur)
    blur.pinEdges(to: self)
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.frame = bounds
    CATransaction.commit()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    updateColors()
  }

  private func updateColors() {
    let base = UIColor.systemBackground.resolvedColor(with: traitCollection)
    gradient.colors = [base.cgColor, base.withAlphaComponent(0).cgColor]
  }
}

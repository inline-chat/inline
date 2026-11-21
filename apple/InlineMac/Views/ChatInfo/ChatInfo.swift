import AppKit
import GRDB
import InlineKit
import InlineUI
import Logger
import Quartz
import RealtimeV2
import SwiftUI
import Translation

enum ChatInfoDefaultTab: Hashable {
  case files
  case media
  case voice
  case links
  case participants
}

private enum ChatVisibilitySelection: String, CaseIterable, Hashable {
  case publicChat
  case privateChat

  var title: String {
    switch self {
      case .publicChat:
        "Public"
      case .privateChat:
        "Private"
    }
  }
}

struct ChatInfo: View {
  @Environment(\.displayScale) private var displayScale
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentStateObject var fullChat: FullChatViewModel
  @EnvironmentStateObject private var mediaState: ChatInfoMediaState
  @EnvironmentStateObject private var documentsState: ChatInfoDocumentsState
  @EnvironmentStateObject private var linksState: ChatInfoLinksState
  @EnvironmentStateObject private var voiceMemosState: ChatInfoVoiceMemosState
  @EnvironmentStateObject private var participantsState: ChatInfoParticipantsState
  @StateObject private var appSettings = AppSettings.shared
  @StateObject private var avatarPreview = ChatInfoAvatarQuickLookPresenter()
  @ObservedObject private var notificationSettings = INUserSettings.current.notification
  @ObservedObject private var agentStore = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared

  let peerId: Peer
  private let defaultTab: ChatInfoDefaultTab?
  @State private var selectedTab: PeerInfoTab
  @State private var didApplyDefaultTab = false
  @State private var resourceResolutionFailed = false
  @State private var isOwnerOrAdmin = false
  @State private var isCreator = false
  @State private var canEditChatInfo = false
  @State private var isSavingIcon = false
  @State private var iconDraft = ""
  @State private var didSyncIconDraft = false
  @State private var showVisibilityPicker = false
  @State private var showTranslationOptions = false
  @State private var showAddParticipants = false
  @State private var showRemoveParticipantConfirmation = false
  @State private var showEditThread = false
  @State private var showBotAccess = false
  @State private var isTranslationEnabled: Bool
  @State private var selectedParticipantIds: Set<Int64> = []
  @State private var participantPendingRemoval: UserInfo?
  @State private var groupPendingRemoval: UserGroup?
  @State private var showRemoveGroupConfirmation = false
  @State private var threadsModel: PeerInfoThreadsModel?
  @State private var ownedBotEditor = OwnedBotEditorPresenter()

  private var userInfo: UserInfo? {
    fullChat.chatItem?.userInfo
  }

  /// The bot this direct chat is with.
  private var botUserInfo: UserInfo? {
    guard let userInfo, userInfo.user.bot else { return nil }
    return userInfo
  }

  private var currentChat: Chat? {
    fullChat.chat ?? fullChat.chatItem?.chat
  }

  private var subject: PeerInfoSubject {
    PeerInfoSubject.resolve(
      peer: peerId,
      chat: currentChat,
      user: userInfo?.user,
      currentUserId: dependencies?.auth.currentUserId
    )
  }

  private var chatTitle: String {
    if let userInfo {
      userInfo.user.fullName
    } else if let chat = currentChat {
      chat.humanReadableTitle ?? "Chat"
    } else {
      "Chat"
    }
  }

  private var chatId: Int64? {
    fullChat.chat?.id ?? fullChat.chatItem?.dialog.chatId
  }

  private var dialog: Dialog? {
    fullChat.chatItem?.dialog
  }

  private var notificationSelection: DialogNotificationSettingSelection {
    dialog?.notificationSelection ?? .global
  }

  private var notifications: PeerInfoNotificationsPresentation {
    PeerInfoNotificationsPresentation(selection: notificationSelection, globalMode: notificationSettings.mode)
  }

  private var isFollowing: Bool {
    dialog?.isFollowingThread == true
  }

  private var headerIconChat: Chat? {
    guard var chat = currentChat else { return nil }
    chat.emoji = didSyncIconDraft ? Self.normalizedEmoji(iconDraft) : Self.normalizedEmoji(chat.emoji)
    return chat
  }

  private var chatIconBinding: Binding<String> {
    Binding(
      get: { iconDraft },
      set: { newValue in
        let normalized = Self.normalizedEmoji(newValue) ?? ""
        didSyncIconDraft = true
        iconDraft = normalized
        updateChatIcon(normalized)
      }
    )
  }

  private var canToggleVisibility: Bool {
    guard peerId.isThread,
          let chat = fullChat.chat,
          chat.spaceId != nil,
          chat.parentChatId == nil,
          isOwnerOrAdmin || isCreator
    else {
      return false
    }
    return true
  }

  private var canAddParticipants: Bool {
    guard peerId.isThread else { return false }
    return ChatParticipantPolicy.canAdd(chat: fullChat.chat)
  }

  private var canManageParticipants: Bool {
    guard peerId.isThread,
          let chat = fullChat.chat,
          chat.isPublic == false
    else {
      return false
    }
    return isOwnerOrAdmin || isCreator
  }

  /// The viewer owns or admins this bot, so its profile and access are theirs to change.
  private var managesBot: Bool {
    guard let botUserInfo else { return false }
    return grants.ownedGrants(botUserID: botUserInfo.user.id) != nil
  }

  /// Chat info opened from its own chat, so Back returns there.
  private var cameFromOwnChat: Bool {
    let index = nav.historyIndex - 1
    guard nav.history.indices.contains(index) else { return false }
    return nav.history[index].route == .chat(peer: peerId)
  }

  private var actions: [PeerInfoAction] {
    PeerInfoAction.actions(
      for: subject,
      context: PeerInfoActionContext(
        isOverOwnChat: cameFromOwnChat,
        supportsInChatSearch: true,
        canAddMembers: canAddParticipants,
        canShareBot: managesBot,
        offersOutputMode: botUserInfo.map { agentStore.offersOutputMode(botUserID: $0.user.id) } ?? false
      )
    )
  }

  private var availableTabs: [PeerInfoTab] {
    PeerInfoTab.tabs(for: subject)
  }

  private var availableTabsKey: String {
    availableTabs.map(\.rawValue).joined(separator: "|")
  }

  private var canEdit: Bool {
    switch subject.kind {
    case .thread, .subthread: canEditChatInfo
    case .bot: managesBot
    case .person, .selfChat: false
    }
  }

  private var permissionsTaskKey: String {
    "\(peerId.toString())-\(fullChat.chat?.id ?? 0)-\(fullChat.chat?.spaceId ?? 0)-\(fullChat.chat?.createdBy ?? 0)-\(dependencies?.auth.currentUserId ?? 0)"
  }

  init(peerId: Peer, defaultTab: ChatInfoDefaultTab? = nil) {
    self.peerId = peerId
    self.defaultTab = defaultTab
    _selectedTab = State(initialValue: PeerInfoTab(defaultTab) ?? (peerId.isThread ? .members : .threads))
    _isTranslationEnabled = State(initialValue: TranslationState.shared.isTranslationEnabled(for: peerId))
    _fullChat = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peerId)
    }
    _mediaState = EnvironmentStateObject { env in
      ChatInfoMediaState(db: env.appDatabase, peer: peerId)
    }
    _documentsState = EnvironmentStateObject { env in
      ChatInfoDocumentsState(db: env.appDatabase, peer: peerId)
    }
    _linksState = EnvironmentStateObject { env in
      ChatInfoLinksState(db: env.appDatabase, peer: peerId)
    }
    _voiceMemosState = EnvironmentStateObject { env in
      ChatInfoVoiceMemosState(db: env.appDatabase, peer: peerId)
    }
    _participantsState = EnvironmentStateObject { env in
      ChatInfoParticipantsState(db: env.appDatabase)
    }
  }

  var body: some View {
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          VStack(spacing: 16) {
            header
            if !actions.isEmpty {
              actionRow
            }
            cards
            PeerInfoMacDeveloperIDs(entries: developerIDs)
          }
          .peerInfoColumn()
          .padding(.top, 18)
          .padding(.bottom, 18)

          Section {
            tabContent
              .peerInfoColumn()
              .padding(.top, 8)
              .padding(.bottom, 28)
          } header: {
            PeerInfoMacTabBar(tabs: availableTabs, selection: resourceTabSelection)
          }
        }
      }
    .frame(maxWidth: .infinity, alignment: .top)
    .navigationTitle(chatTitle)
    .toolbar { toolbarContent }
    .onAppear {
      ensureSelectedTab()
      updateViewModels()
      syncTranslationState()
      syncIconDraft()
      startThreadsIfNeeded()
    }
    .onDisappear {
      deactivateResources()
      threadsModel?.stop()
    }
    .task(id: permissionsTaskKey) {
      await loadVisibilityPermissions()
    }
    .task(id: peerId) {
      await resolveResourceChat()
    }
    .task(id: botUserInfo?.user.id) {
      guard let bot = botUserInfo?.user else { return }
      grants.ensureLoaded(botUserID: bot.id)
      await agentStore.loadDirectChatOutputModes(botUserID: bot.id)
    }
    .onChange(of: chatId) { _, _ in
      if chatId != nil {
        resourceResolutionFailed = false
      }
      updateViewModels()
      syncIconDraft()
    }
    .onChange(of: fullChat.chat?.emoji) { _, _ in
      syncIconDraft()
    }
    .onChange(of: availableTabsKey) { _, _ in
      ensureSelectedTab()
      updateViewModels()
      startThreadsIfNeeded()
    }
    .onReceive(TranslationState.shared.subject) { event in
      let (eventPeer, enabled) = event
      guard eventPeer == peerId else { return }
      isTranslationEnabled = enabled
    }
    .modifier(presentations)
    .modifier(ownedBotEditor.presentations())
  }

  // MARK: Header

  @ViewBuilder
  private var avatar: some View {
    if let userInfo {
      if Self.hasPhoto(userInfo) {
        Button {
          avatarPreview.show(userInfo: userInfo, scale: displayScale)
        } label: {
          ChatIcon(peer: .user(userInfo), size: 88)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help("Show Photo")
        .accessibilityLabel("Show \(userInfo.user.shortDisplayName)’s photo")
      } else {
        ChatIcon(peer: .user(userInfo), size: 88)
          .accessibilityHidden(true)
      }
    } else if let chat = headerIconChat {
      if peerId.isThread, canEditChatInfo {
        EmojiTextFieldPicker(
          emoji: chatIconBinding,
          targetSize: CGSize(width: 88, height: 88),
          isDisabled: isSavingIcon,
          accessibilityLabel: "Thread icon"
        ) { _, _, isDisabled in
          ChatIcon(peer: .chat(chat), size: 88)
            .opacity(isDisabled ? 0.65 : 1)
            .overlay(alignment: .bottomTrailing) {
              Image(systemName: "face.smiling")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .accessibilityHidden(true)
            }
        }
        .help("Change Icon")
      } else {
        ChatIcon(peer: .chat(chat), size: 88)
          .accessibilityHidden(true)
      }
    } else {
      Circle()
        .fill(Color.secondary.opacity(0.15))
        .frame(width: 88, height: 88)
    }
  }

  private var header: some View {
    VStack(spacing: 6) {
      avatar
        .padding(.bottom, 4)

      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(chatTitle)
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .accessibilityAddTraits(.isHeader)

        if let user = userInfo?.user {
          UserNameBadges(user: user, spaceID: nil, size: 18)
        }
      }

      subtitle
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var subtitle: some View {
    switch subject.kind {
    case .bot:
      if let bot = botUserInfo?.user {
        BotChatInfoStatusLine(user: bot)
      }
    case .person:
      if let text = PeerInfoSubtitle.person(
        focusActive: userInfo?.focus?.isActive() == true,
        localTime: userInfo.flatMap { PeerInfoPersonFields(user: $0.user).localTime }
      ) {
        HStack(spacing: 4) {
          if userInfo?.focus?.isActive() == true {
            Image(systemName: "moon.fill").font(.caption)
          }
          Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    case .selfChat:
      Text("Only you can see this chat")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .thread, .subthread:
      Text(PeerInfoSubtitle.thread(subject: subject, memberCount: memberCount))
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var memberCount: Int? {
    guard let model = participantsState.participantsViewModel else { return nil }
    let count = model.effectiveUserIds.count
    return count > 0 ? count : model.participants.count
  }

  private static func hasPhoto(_ userInfo: UserInfo) -> Bool {
    userInfo.user.getLocalURL() != nil || userInfo.user.getRemoteURL() != nil
      || userInfo.profilePhoto?.first.map { $0.getLocalURL() != nil || $0.getRemoteURL() != nil } == true
  }

  // MARK: Actions

  private var actionRow: some View {
    PeerInfoActionRow(count: actions.count) {
      ForEach(actions) { action in
        actionButton(action)
      }
    }
  }

  @ViewBuilder
  private func actionButton(_ action: PeerInfoAction) -> some View {
    switch action {
    case .open:
      tileButton(
        subject.isThread ? "Open" : "Message",
        systemImage: subject.isThread ? "bubble.left.and.bubble.right" : "message",
        help: subject.isThread ? "Open this thread" : "Open your chat"
      ) {
        dependencies?.requestOpenChat(peer: peerId)
      }
    case .search:
      tileButton("Search", systemImage: "magnifyingglass", help: "Search messages in this chat") {
        searchInChat()
      }
    case .notifications:
      notificationsButton
    case .follow:
      tileButton(
        isFollowing ? "Following" : "Follow",
        systemImage: isFollowing ? "checkmark.circle" : "eye",
        help: ChatToolbarFollowPresentation(isFollowing: isFollowing).tooltip
      ) {
        ChatToolbarFollowButton.toggleFollowMode(peer: peerId, isFollowing: isFollowing)
      }
      .accessibilityValue(isFollowing ? "On" : "Off")
    case .output:
      if let bot = botUserInfo {
        AgentOutputModeSettingsRow(peer: peerId, botUserID: bot.user.id, style: .actionTile)
      }
    case .share:
      tileButton("Share", systemImage: "person.crop.circle.badge.plus", help: "Choose who can message this bot") {
        showBotAccess = true
      }
    case .addMembers:
      tileButton("Add", systemImage: "person.badge.plus", help: "Add people or groups to this thread") {
        showAddParticipants = true
      }
    }
  }

  private func tileButton(
    _ title: String,
    systemImage: String,
    detail: String? = nil,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      PeerInfoActionTile(title, systemImage: systemImage, detail: detail)
    }
    .buttonStyle(PeerInfoActionTileButtonStyle())
    .help(help)
  }

  /// Click mutes or unmutes at once; click and hold, or right-click, for every choice.
  private var notificationsButton: some View {
    let notifications = notifications
    return Menu {
      notificationMenuItems
    } label: {
      PeerInfoActionTile(
        notifications.isMuted ? "Unmute" : "Mute",
        systemImage: notifications.isMuted ? "bell.slash.fill" : "bell",
        detail: notifications.isMuted ? nil : notificationDetail(notifications),
        isHighlighted: notifications.isMuted
      )
    } primaryAction: {
      setNotifications(notifications.quickToggleSelection, announce: true)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(PeerInfoActionTileButtonStyle())
    .contextMenu { notificationMenuItems }
    .help(notifications.isMuted ? "Unmute this chat. Hold for more options." : "Mute this chat. Hold for more options.")
    .accessibilityLabel(notifications.isMuted ? "Unmute" : "Mute")
    .accessibilityValue(notifications.accessibilityValue)
  }

  /// "Mentions" under Mute when only mentions notify, so the row shows the state.
  private func notificationDetail(_ notifications: PeerInfoNotificationsPresentation) -> String? {
    switch notifications.effectiveMode {
    case .mentions, .onlyMentions, .importantOnly: "Mentions"
    default: nil
    }
  }

  @ViewBuilder
  private var notificationMenuItems: some View {
    let defaultMode = PeerInfoNotificationsPresentation(selection: .global, globalMode: notificationSettings.mode)
    Section {
      notificationMenuItem(.global, title: "Default (\(defaultMode.isMuted ? "Muted" : defaultMode.title == "Mentions" ? "Mentions" : "All Messages"))")
    }
    Section("This Chat") {
      notificationMenuItem(.all, title: "All Messages")
      notificationMenuItem(.mentions, title: "Mentions Only")
      notificationMenuItem(.none, title: "None")
    }
  }

  private func notificationMenuItem(_ selection: DialogNotificationSettingSelection, title: String) -> some View {
    Toggle(isOn: Binding(
      get: { notificationSelection == selection },
      set: { isOn in if isOn { setNotifications(selection, announce: false) } }
    )) {
      Text(title)
      Text(selection.menuDescription)
    }
  }

  private func setNotifications(_ selection: DialogNotificationSettingSelection, announce: Bool) {
    updateNotificationSettings(selection)
    guard announce else { return }
    let next = PeerInfoNotificationsPresentation(selection: selection, globalMode: notificationSettings.mode)
    ToastCenter.shared.showSuccess(next.isMuted ? "Muted" : "Unmuted")
  }

  private func searchInChat() {
    if cameFromOwnChat {
      nav.goBack()
    } else {
      dependencies?.requestOpenChat(peer: peerId)
    }
    // The chat view answers Find through the responder chain once it is on screen.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      NSApp.sendAction(#selector(InChatSearchMenuActions.showInChatSearch(_:)), to: nil, from: nil)
    }
  }

  // MARK: Cards

  @ViewBuilder
  private var cards: some View {
    switch subject.kind {
    case .person:
      if let user = userInfo?.user {
        PeerInfoPersonCard(user: user)
      }
    case .bot:
      if let bot = botUserInfo {
        PeerInfoCard {
          PeerInfoBotAboutRow(user: bot.user)
          PeerInfoBotRuntimeRow(user: bot.user)
          PeerInfoBotAccessRow(bot: bot) { ownerId in
            dependencies?.openChatInfo(peer: .user(id: ownerId))
          }
        }
      }
    case .thread, .subthread:
      placeCard
    case .selfChat:
      EmptyView()
    }
  }

  /// Where a thread lives: its space, and for a subthread the chat and message it came from.
  @ViewBuilder
  private var placeCard: some View {
    let space = spaceForThread
    let parent = parentChat
    if space != nil || subject.parentChatId != nil {
      PeerInfoCard {
        if let space {
          PeerInfoActionRowButton(
            caption: nil,
            title: space.displayName,
            detail: "Space",
            kind: .navigation,
            help: "Show this space in the sidebar",
            action: { dependencies?.openSpaceContext(id: space.id, name: space.displayName, keeping: peerId) },
            leading: { SpaceAvatar(space: space, size: 24, cornerRadius: 6) },
            trailing: { EmptyView() }
          )
        }
        if let parentChatId = subject.parentChatId {
          PeerInfoActionRowButton(
            caption: nil,
            title: parent?.humanReadableTitle ?? "Parent thread",
            detail: subject.parentMessageId != nil ? "Started from a message here" : "Parent thread",
            kind: .navigation,
            help: subject.parentMessageId != nil ? "Show the message this thread started from" : "Open the parent thread",
            action: {
              let parentPeer = parent?.deepLinkPeer ?? .thread(id: parentChatId)
              dependencies?.requestOpenChat(peer: parentPeer, targetMessageId: subject.parentMessageId)
            },
            leading: { PeerInfoRowIcon(systemImage: "arrow.turn.up.left", color: .gray) },
            trailing: { EmptyView() }
          )
        }
      }
    }
  }

  /// Raw IDs for Developer Mode, which shows them in a card of their own.
  private var developerIDs: [(label: String, id: Int64)] {
    var entries: [(label: String, id: Int64)] = []
    if let chatId, chatId > 0 { entries.append(("Chat ID", chatId)) }
    if case let .user(userId) = peerId { entries.append(("User ID", userId)) }
    return entries
  }

  private var spaceForThread: Space? {
    guard let spaceId = subject.spaceId else { return nil }
    return ObjectCache.shared.getSpace(id: spaceId)
  }

  private var parentChat: Chat? {
    guard let parentChatId = subject.parentChatId else { return nil }
    return ObjectCache.shared.getChat(id: parentChatId)
  }

  // MARK: Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if canEdit {
        Button("Edit") { edit() }
          .help(subject.isThread ? "Edit this thread’s name, icon and visibility" : "Edit this bot’s profile")
      }
      if let dependencies {
        ChatToolbarMenuButton(
          peer: peerId,
          dependencies: dependencies,
          chatInfo: ChatInfoMenuExtras(
            managesBot: managesBot,
            isTranslationEnabled: isTranslationEnabled,
            translationUIEnabled: appSettings.translationUIEnabled,
            onToggleTranslation: { TranslationState.shared.setTranslationEnabled(!isTranslationEnabled, for: peerId) },
            onTranslationOptions: { showTranslationOptions = true },
            onBotSettings: {
              if let bot = botUserInfo {
                ownedBotEditor.open(.settings, botUserID: bot.user.id, realtimeV2: realtimeV2)
              }
            }
          )
        )
      }
    }
  }

  private func edit() {
    switch subject.kind {
    case .thread, .subthread:
      showEditThread = true
    case .bot:
      if let bot = botUserInfo {
        ownedBotEditor.open(.profile, botUserID: bot.user.id, realtimeV2: realtimeV2)
      }
    case .person, .selfChat:
      break
    }
  }

  // MARK: Tabs

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
    case .files:
      filesTab
    case .media:
      mediaTab
    case .voice:
      voiceTab
    case .links:
      linksTab
    case .members:
      participantsTab
    case .threads:
      threadsTab
    }
  }

  @ViewBuilder
  private var threadsTab: some View {
    if let threadsModel {
      PeerInfoMacThreadsList(model: threadsModel, emptyMessage: subject.isThread
        ? "No subthreads yet. Reply in a thread to start one."
        : "No shared threads yet.")
    } else {
      resourceResolutionView
    }
  }

  private func startThreadsIfNeeded() {
    guard threadsModel == nil, let source = PeerInfoThreadsModel.source(for: subject) else {
      threadsModel?.start()
      return
    }
    let model = PeerInfoThreadsModel(source: source)
    threadsModel = model
    model.start()
  }

  @ViewBuilder
  private var mediaTab: some View {
    if let model = mediaState.mediaViewModel {
      ChatInfoMediaList(mediaViewModel: model, onShowInChat: showMessageInChat)
    } else {
      resourceResolutionView
    }
  }

  // MARK: Sheets

  private var presentations: some ViewModifier {
    ChatInfoPresentations(
      showVisibilityPicker: $showVisibilityPicker,
      showTranslationOptions: $showTranslationOptions,
      showAddParticipants: $showAddParticipants,
      showRemoveParticipantConfirmation: $showRemoveParticipantConfirmation,
      showRemoveGroupConfirmation: $showRemoveGroupConfirmation,
      showEditThread: $showEditThread,
      showBotAccess: $showBotAccess,
      selectedParticipantIds: $selectedParticipantIds,
      participantPendingRemoval: participantPendingRemoval,
      groupPendingRemoval: groupPendingRemoval,
      peer: peerId,
      chat: fullChat.chat,
      bot: botUserInfo,
      dependencies: dependencies,
      participants: participantsState.participantsViewModel?.participants ?? [],
      groupParticipants: participantsState.participantsViewModel?.groupParticipants ?? [],
      canToggleVisibility: canToggleVisibility,
      canEditInfo: canEditChatInfo,
      onConfirmPrivate: { ids in updateVisibility(isPublic: false, participantIds: Array(ids)) },
      onChooseVisibility: { handleVisibilitySelection($0 ? .publicChat : .privateChat) },
      onRemoveParticipant: { removeParticipant(userId: $0.user.id) },
      onRemoveGroup: { removeGroupParticipant(groupId: $0.id) }
    )
  }

  private func showMessageInChat(_ message: Message) {
    dependencies?.requestOpenChat(peer: peerId, targetMessageId: message.messageId)
  }

  @ViewBuilder
  private var filesTab: some View {
    if let documentsViewModel = documentsState.documentsViewModel {
      ChatInfoFilesList(documentsViewModel: documentsViewModel, onShowInChat: showMessageInChat)
    } else {
      resourceResolutionView
    }
  }

  @ViewBuilder
  private var voiceTab: some View {
    if let voiceMemosViewModel = voiceMemosState.voiceMemosViewModel {
      ChatInfoVoiceMemosList(
        voiceMemosViewModel: voiceMemosViewModel,
        accentColor: themeAccentColor,
        onShowInChat: showMessageInChat
      )
    } else {
      resourceResolutionView
    }
  }

  private var themeAccentColor: Color {
    _ = appSettings.themeRevision
    return Color(nsColor: Theme.accentColor)
  }

  @ViewBuilder
  private var linksTab: some View {
    if let linksViewModel = linksState.linksViewModel {
      ChatInfoLinksList(linksViewModel: linksViewModel, onShowInChat: showMessageInChat)
    } else {
      resourceResolutionView
    }
  }

  private var resourceResolutionView: some View {
    VStack(spacing: 8) {
      if resourceResolutionFailed {
        Text("Couldn't load chat.").foregroundStyle(.secondary)
        Button("Retry") { Task { await resolveResourceChat() } }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }

  @MainActor
  private func resolveResourceChat() async {
    resourceResolutionFailed = false
    do {
      if chatId == nil {
        let resolved = try await fullChat.ensureChat()
        resourceResolutionFailed = resolved == nil
      } else if peerId.asUserId() != nil {
        _ = try await realtimeV2.send(.getChat(peer: peerId))
      }
    } catch {
      guard !Task.isCancelled else { return }
      resourceResolutionFailed = chatId == nil
    }
  }

  @ViewBuilder
  private var participantsTab: some View {
    if let participantsViewModel = participantsState.participantsViewModel {
      ChatInfoParticipantsList(
        participantsViewModel: participantsViewModel,
        currentUserId: dependencies?.auth.currentUserId,
        spaceId: currentChat?.spaceId,
        isPublic: currentChat?.isPublic == true,
        canAddParticipants: canAddParticipants,
        canManageParticipants: canManageParticipants,
        onAddParticipants: {
          showAddParticipants = true
        },
        onOpenChatInfo: { userInfo in
          openUserChatInfo(userInfo)
        },
        onMessage: { userInfo in
          dependencies?.requestOpenChat(peer: .user(id: userInfo.user.id))
        },
        onRequestRemove: { userInfo in
          participantPendingRemoval = userInfo
          showRemoveParticipantConfirmation = true
        },
        onRequestRemoveGroup: { group in
          groupPendingRemoval = group
          showRemoveGroupConfirmation = true
        }
      )
    } else {
      HStack {
        Spacer()
        ProgressView()
          .controlSize(.small)
        Spacer()
      }
      .padding(.vertical, 32)
    }
  }

  private func ensureSelectedTab() {
    if !didApplyDefaultTab, let preferredTab = PeerInfoTab(defaultTab), availableTabs.contains(preferredTab) {
      selectedTab = preferredTab
      didApplyDefaultTab = true
      return
    }

    guard availableTabs.contains(selectedTab) else {
      selectedTab = availableTabs.first ?? .media
      return
    }
  }

  private var resourceTabSelection: Binding<PeerInfoTab> {
    Binding(get: { selectedTab }, set: { tab in
      guard tab != selectedTab else { return }
      deactivateResources()
      selectedTab = tab
      updateViewModels()
    })
  }

  private func deactivateResources() {
    mediaState.mediaViewModel?.deactivate()
    documentsState.documentsViewModel?.deactivate()
    linksState.linksViewModel?.deactivate()
    voiceMemosState.voiceMemosViewModel?.deactivate()
  }

  private func updateViewModels() {
    if selectedTab != .media {
      mediaState.mediaViewModel?.deactivate()
    }
    if selectedTab != .files {
      documentsState.documentsViewModel?.deactivate()
    }
    if selectedTab != .links {
      linksState.linksViewModel?.deactivate()
    }
    if selectedTab != .voice {
      voiceMemosState.voiceMemosViewModel?.deactivate()
    }
    guard let chatId, chatId > 0 else { return }
    switch selectedTab {
      case .media: mediaState.updateChatId(chatId)
      case .files: documentsState.updateChatId(chatId)
      case .links: linksState.updateChatId(chatId)
      case .voice: voiceMemosState.updateChatId(chatId)
      default: break
    }
    if availableTabs.contains(.members) {
      participantsState.updateChatId(chatId)
    }
  }

  private func syncTranslationState() {
    isTranslationEnabled = TranslationState.shared.isTranslationEnabled(for: peerId)
  }

  private func syncIconDraft() {
    iconDraft = Self.normalizedEmoji(fullChat.chat?.emoji ?? fullChat.chatItem?.chat?.emoji) ?? ""
    didSyncIconDraft = true
  }

  private func updateChatIcon(_ emoji: String) {
    guard canEditChatInfo, !isSavingIcon else {
      syncIconDraft()
      return
    }
    guard case let .thread(chatId) = peerId else { return }

    let currentEmoji = Self.normalizedEmoji(fullChat.chat?.emoji ?? fullChat.chatItem?.chat?.emoji)
    let nextEmoji = Self.normalizedEmoji(emoji)
    guard currentEmoji != nextEmoji else { return }

    isSavingIcon = true
    Task {
      do {
        _ = try await realtimeV2.send(.updateChatInfo(
          chatID: chatId,
          title: nil,
          emoji: nextEmoji ?? ""
        ))
        await MainActor.run {
          isSavingIcon = false
        }
      } catch {
        Log.shared.error("Failed to update chat icon", error: error)
        await MainActor.run {
          isSavingIcon = false
          syncIconDraft()
        }
      }
    }
  }

  private func copyThreadIdToClipboard(_ threadId: Int64) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(String(threadId), forType: .string)
    ToastCenter.shared.showSuccess("Copied chat ID")
  }

  private func loadVisibilityPermissions() async {
    guard peerId.isThread else {
      isOwnerOrAdmin = false
      isCreator = false
      canEditChatInfo = false
      return
    }
    guard let dependencies,
          let chat = fullChat.chat,
          let currentUserId = dependencies.auth.currentUserId
    else {
      isOwnerOrAdmin = false
      isCreator = false
      canEditChatInfo = false
      return
    }

    do {
      canEditChatInfo = try await dependencies.database.dbWriter.read { db in
        try ChatRenamePermission.canRename(peer: peerId, currentUserId: currentUserId, db: db)
      }
    } catch {
      canEditChatInfo = false
      Log.shared.error("Failed to load chat edit permissions", error: error)
    }

    isCreator = chat.createdBy == currentUserId
    guard let spaceId = chat.spaceId else {
      isOwnerOrAdmin = false
      return
    }

    do {
      let member = try await dependencies.database.dbWriter.read { db in
        try Member
          .filter(Column("spaceId") == spaceId)
          .filter(Column("userId") == currentUserId)
          .fetchOne(db)
      }
      isOwnerOrAdmin = member?.role == .owner || member?.role == .admin
    } catch {
      isOwnerOrAdmin = false
      Log.shared.error("Failed to load chat permissions", error: error)
    }
  }

  private func handleVisibilitySelection(_ selection: ChatVisibilitySelection) {
    guard canToggleVisibility,
          let chat = fullChat.chat
    else { return }

    let currentlyPublic = chat.isPublic == true
    let isPublic = selection == .publicChat
    guard isPublic != currentlyPublic else { return }

    if isPublic {
      updateVisibility(isPublic: true, participantIds: [])
    } else {
      guard let currentUserId = dependencies?.auth.currentUserId else { return }
      selectedParticipantIds = [currentUserId]
      showVisibilityPicker = true
    }
  }

  private func updateVisibility(isPublic: Bool, participantIds: [Int64]) {
    guard case let .thread(chatId) = peerId else { return }

    Task {
      do {
        _ = try await Api.realtime.send(.updateChatVisibility(
          chatID: chatId,
          isPublic: isPublic,
          participantIDs: participantIds
        ))
        do {
          try await Api.realtime.send(.getChatParticipants(chatID: chatId))
        } catch {
          Log.shared.error("Failed to refetch chat participants after visibility update", error: error)
        }
      } catch {
        Log.shared.error("Failed to update chat visibility", error: error)
      }
    }
  }

  private func removeParticipant(userId: Int64) {
    guard case let .thread(chatId) = peerId else { return }
    if let currentUserId = dependencies?.auth.currentUserId, currentUserId == userId {
      return
    }

    Task {
      do {
        _ = try await Api.realtime.send(.removeChatParticipant(chatID: chatId, userID: userId))
        do {
          try await Api.realtime.send(.getChatParticipants(chatID: chatId))
        } catch {
          Log.shared.error("Failed to refetch chat participants after removal", error: error)
        }
      } catch {
        Log.shared.error("Failed to remove participant", error: error)
      }
    }
  }

  private func removeGroupParticipant(groupId: Int64) {
    guard case let .thread(chatId) = peerId else { return }

    Task {
      do {
        _ = try await Api.realtime.send(.removeChatParticipant(chatID: chatId, groupID: groupId))
        do {
          try await Api.realtime.send(.getChatParticipants(chatID: chatId))
        } catch {
          Log.shared.error("Failed to refetch chat participants after group removal", error: error)
        }
      } catch {
        Log.shared.error("Failed to remove group participant", error: error)
      }
    }
  }

  private func openUserChatInfo(_ userInfo: UserInfo) {
    let peer = Peer.user(id: userInfo.user.id)
    if let dependencies {
      dependencies.openChatInfo(peer: peer)
    } else {
      nav.open(.chatInfo(peer: peer))
    }
  }

  private func updateNotificationSettings(_ selection: DialogNotificationSettingSelection) {
    guard selection != notificationSelection else { return }

    Task {
      do {
        _ = try await realtimeV2.send(.updateDialogNotificationSettings(peerId: peerId, selection: selection))
      } catch {
        Log.shared.error("Failed to update dialog notification settings", error: error)
      }
    }
  }

  private static func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return nil }
    return String(first)
  }
}

extension PeerInfoTab {
  /// The tab a chat info route asks for, such as Files from a file's menu.
  init?(_ tab: ChatInfoDefaultTab?) {
    switch tab {
    case .none: return nil
    case .participants: self = .members
    case .files: self = .files
    case .media: self = .media
    case .voice: self = .voice
    case .links: self = .links
    }
  }
}

extension View {
  /// The readable column chat info lays its content in.
  func peerInfoColumn() -> some View {
    frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 20)
  }
}

/// A title on the leading edge of the chat info card and its control on the
/// trailing edge.
struct ChatInfoRow<Content: View>: View {
  private let title: String
  private let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 140, alignment: .leading)

      Spacer(minLength: 0)

      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
  }
}

struct InlineMenuPickerLabel: View {
  let title: String
  let systemImage: String
  let disabled: Bool

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .regular))
        .frame(width: 14)

      Text(title)
        .lineLimit(1)

      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
    }
    .foregroundStyle(disabled ? .secondary : .primary)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

private final class ChatInfoAvatarQuickLookPresenter: NSObject, ObservableObject {
  private var item: ChatInfoAvatarPreviewItem?
  private var tempURL: URL?
  private var isLoading = false

  func show(userInfo: UserInfo, scale: CGFloat) {
    Task { @MainActor in
      await open(userInfo: userInfo, scale: scale)
    }
  }

  @MainActor
  private func open(userInfo: UserInfo, scale: CGFloat) async {
    guard !isLoading else { return }

    let user = userInfo.user
    let title = user.displayName.isEmpty ? "Avatar" : user.displayName

    guard let source = UserAvatarImageSource(user: user, scale: scale) else {
      ToastCenter.shared.showError("Avatar isn't available")
      return
    }

    isLoading = true
    defer { isLoading = false }

    do {
      let data = try await source.originalImageData()
      guard let image = NSImage(data: data) else { throw ChatInfoAvatarPreviewError.imageEncodingFailed }
      let previewURL = try makeTempURL(for: image)
      present(url: previewURL, title: title)
    } catch {
      ToastCenter.shared.showError("Failed to open avatar")
    }
  }

  @MainActor
  private func present(url: URL, title: String) {
    item = ChatInfoAvatarPreviewItem(url: url, title: title)

    guard let panel = QLPreviewPanel.shared() else {
      return
    }

    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    setLargeFrame(for: panel)
    panel.makeKeyAndOrderFront(nil)
  }

  private func makeTempURL(for image: NSImage) throws -> URL {
    cleanupTempURL()

    guard let data = image.tiffRepresentation else {
      throw ChatInfoAvatarPreviewError.imageEncodingFailed
    }

    let dir = try FileManager.default.url(
      for: .itemReplacementDirectory,
      in: .userDomainMask,
      appropriateFor: FileManager.default.temporaryDirectory,
      create: true
    )
    let url = dir.appending(path: "avatar-\(UUID().uuidString).tiff")
    try data.write(to: url, options: .atomic)
    tempURL = url
    return url
  }

  private func setLargeFrame(for panel: QLPreviewPanel) {
    guard let visibleFrame = NSScreen.main?.visibleFrame else {
      return
    }

    let width = min(max(720, visibleFrame.width * 0.52), visibleFrame.width - 80)
    let height = min(max(720, visibleFrame.height * 0.72), visibleFrame.height - 80)
    let frame = NSRect(
      x: visibleFrame.midX - width / 2,
      y: visibleFrame.midY - height / 2,
      width: width,
      height: height
    )
    panel.setFrame(frame, display: true, animate: true)
  }

  private func cleanupTempURL() {
    guard let tempURL else { return }
    try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    self.tempURL = nil
  }

  deinit {
    cleanupTempURL()
  }
}

extension ChatInfoAvatarQuickLookPresenter: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    item == nil ? 0 : 1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    item
  }
}

private final class ChatInfoAvatarPreviewItem: NSObject, QLPreviewItem {
  let url: URL
  let title: String

  init(url: URL, title: String) {
    self.url = url
    self.title = title
  }

  @objc var previewItemURL: URL? {
    url
  }

  var previewItemTitle: String? {
    title
  }
}

private enum ChatInfoAvatarPreviewError: Error {
  case imageEncodingFailed
}

/// The Members tab: who can read a thread, directly or through a group.
/// You come first, then owners and admins, then everyone by name.
private struct ChatInfoParticipantsList: View {
  @ObservedObject var participantsViewModel: ChatParticipantsWithMembersViewModel
  let currentUserId: Int64?
  let spaceId: Int64?
  let isPublic: Bool
  let canAddParticipants: Bool
  let canManageParticipants: Bool
  let onAddParticipants: () -> Void
  let onOpenChatInfo: (UserInfo) -> Void
  let onMessage: (UserInfo) -> Void
  let onRequestRemove: (UserInfo) -> Void
  let onRequestRemoveGroup: (UserGroup) -> Void

  @State private var roles: [Int64: MemberRole] = [:]

  private var sortedParticipants: [UserInfo] {
    participantsViewModel.participants.sorted { lhs, rhs in
      let lhsRank = rank(lhs)
      let rhsRank = rank(rhs)
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      let comparison = lhs.user.displayName.localizedCaseInsensitiveCompare(rhs.user.displayName)
      if comparison == .orderedSame { return lhs.user.id < rhs.user.id }
      return comparison == .orderedAscending
    }
  }

  private func rank(_ info: UserInfo) -> Int {
    if info.user.id == currentUserId { return 0 }
    switch roles[info.user.id] {
    case .owner: return 1
    case .admin: return 2
    default: return info.user.bot ? 4 : 3
    }
  }

  private var sortedGroups: [UserGroup] {
    participantsViewModel.groupParticipants.sorted { lhs, rhs in
      let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
      if comparison == .orderedSame { return lhs.id < rhs.id }
      return comparison == .orderedAscending
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if isPublic {
        PeerInfoCard {
          HStack(spacing: 10) {
            PeerInfoRowIcon(systemImage: "globe")
            Text("Everyone in this space can read and join")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
        }
      }

      if !sortedGroups.isEmpty {
        PeerInfoCard(sortedGroups.count == 1 ? "1 Group" : "\(sortedGroups.count) Groups") {
          ForEach(sortedGroups) { group in
            ChatInfoGroupAccessRow(
              group: group,
              canRemove: canManageParticipants,
              onRequestRemove: { onRequestRemoveGroup(group) }
            )
          }
        }
      }

      PeerInfoCard(sortedParticipants.count == 1 ? "1 Person" : "\(sortedParticipants.count) People") {
        if canAddParticipants {
          PeerInfoActionRowButton(
            title: "Add Members",
            kind: .action(systemImage: "plus"),
            help: "Add people or groups to this thread",
            action: onAddParticipants,
            leading: { PeerInfoRowIcon(systemImage: "person.badge.plus") },
            trailing: { EmptyView() }
          )
        }
        ForEach(sortedParticipants, id: \.id) { participant in
          ChatInfoParticipantRow(
            participant: participant,
            role: roles[participant.user.id],
            isCurrentUser: participant.user.id == currentUserId,
            canRemove: canManageParticipants && participant.user.id != currentUserId,
            onOpenChatInfo: { onOpenChatInfo(participant) },
            onMessage: { onMessage(participant) },
            onRequestRemove: { onRequestRemove(participant) }
          )
        }
        if sortedParticipants.isEmpty, !canAddParticipants {
          Text("No one has been added yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
      }
    }
    .task {
      await participantsViewModel.refetchParticipants()
    }
    .task(id: spaceId) {
      guard let spaceId else { return }
      let members = (try? await AppDatabase.shared.reader.read { db in
        try Member.filter(Member.Columns.spaceId == spaceId).fetchAll(db)
      }) ?? []
      roles = Dictionary(members.map { ($0.userId, $0.role) }, uniquingKeysWith: { first, _ in first })
    }
  }
}

private struct ChatInfoGroupAccessRow: View {
  let group: UserGroup
  let canRemove: Bool
  let onRequestRemove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      PeerInfoRowIcon(systemImage: "person.3.fill")
        .frame(width: 30)

      VStack(alignment: .leading, spacing: 1) {
        Text(group.name)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if canRemove {
        Button(role: .destructive, action: onRequestRemove) {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove group access")
        .accessibilityLabel("Remove \(group.name)")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    .contextMenu {
      if canRemove {
        Button(role: .destructive, action: onRequestRemove) {
          Label("Remove Group Access", systemImage: "minus.circle")
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var subtitle: String {
    let count = group.memberCount == 1 ? "1 person" : "\(group.memberCount) people"
    guard let description = group.description, !description.isEmpty else { return count }
    return "\(description) · \(count)"
  }
}

private struct ChatInfoParticipantRow: View {
  let participant: UserInfo
  let role: MemberRole?
  let isCurrentUser: Bool
  let canRemove: Bool
  let onOpenChatInfo: () -> Void
  let onMessage: () -> Void
  let onRequestRemove: () -> Void

  @ObservedObject private var agentStore = AgentWorkStateStore.shared
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onOpenChatInfo) {
        HStack(spacing: 10) {
          UserAvatar(user: participant.user, size: 30)
            .overlay(alignment: .bottomTrailing) { botDot }

          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
              Text(participant.user.displayName)
                .lineLimit(1)
              if isCurrentUser {
                Text("You")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
              }
            }
            if let detail {
              Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          if let role, role != .member {
            Text(role == .owner ? "owner" : "admin")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(role == .owner ? Color.purple : Color.green)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(
                (role == .owner ? Color.purple : Color.green).opacity(0.14),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
              )
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Show \(participant.user.shortDisplayName)’s info")

      if canRemove {
        Button(role: .destructive, action: onRequestRemove) {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .opacity(isHovered ? 1 : 0.35)
        .help("Remove from this thread")
        .accessibilityLabel("Remove \(participant.user.shortDisplayName)")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(isHovered ? Color.primary.opacity(0.04) : .clear)
    .onHover { isHovered = $0 }
    .contextMenu {
      if !isCurrentUser {
        Button("Message", systemImage: "message", action: onMessage)
      }
      Button(action: onOpenChatInfo) {
        if participant.user.bot, isOwnedBot {
          Label("Manage Bot…", systemImage: "slider.horizontal.3")
        } else {
          Label("Show Info", systemImage: "info.circle")
        }
      }
      if canRemove {
        Divider()
        Button(role: .destructive, action: onRequestRemove) {
          Label("Remove from Thread", systemImage: "minus.circle")
        }
      }
    }
    .task(id: participant.user.id) {
      if participant.user.bot {
        AgentGrantStore.shared.ensureLoaded(botUserID: participant.user.id)
      }
    }
  }

  /// Bots show whether they can answer; people's presence stays private.
  private var detail: String? {
    if participant.user.bot {
      return BotStatusSummary.make(user: participant.user, runtime: agentStore.runtimeInfo(botUserID: participant.user.id))?.title ?? "bot"
    }
    if let username = participant.user.username, !username.isEmpty {
      return "@\(username)"
    }
    return nil
  }

  @ViewBuilder
  private var botDot: some View {
    if participant.user.bot,
       let status = BotStatusSummary.make(user: participant.user, runtime: agentStore.runtimeInfo(botUserID: participant.user.id))
    {
      Circle()
        .fill(status.tone.color)
        .frame(width: 9, height: 9)
        .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
        .accessibilityHidden(true)
    }
  }

  private var isOwnedBot: Bool {
    participant.user.bot && AgentGrantStore.shared.ownedGrants(botUserID: participant.user.id) != nil
  }
}

@MainActor
private final class ChatInfoParticipantsState: ObservableObject {
  @Published private(set) var participantsViewModel: ChatParticipantsWithMembersViewModel?

  private let db: AppDatabase
  private var currentChatId: Int64 = 0

  init(db: AppDatabase) {
    self.db = db
  }

  func updateChatId(_ chatId: Int64) {
    guard chatId > 0 else { return }
    guard chatId != currentChatId else { return }
    currentChatId = chatId
    participantsViewModel = ChatParticipantsWithMembersViewModel(db: db, chatId: chatId)
  }
}

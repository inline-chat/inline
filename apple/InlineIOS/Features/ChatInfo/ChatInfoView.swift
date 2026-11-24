import Auth
import Combine
import Foundation
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI
import Translation

struct ChatInfoView: View {
  let chatItem: SpaceChatItem
  let isPresentedModally: Bool
  @StateObject var participantsWithMembersViewModel: ChatParticipantsWithMembersViewModel
  @EnvironmentStateObject private var resources: ChatInfoResourcesState
  @EnvironmentStateObject var spaceMembersViewModel: SpaceMembersViewModel
  @StateObject var spaceFullMembersViewModel: SpaceFullMembersViewModel
  @StateObject var userGroupsViewModel: UserGroupsViewModel
  @State var space: Space?
  @State var isSearching = false
  @State var searchText = ""
  @State var searchResults: [UserInfo] = []
  @State var isSearchingState = false
  @State var participantSearchTask: Task<Void, Never>?
  @State var participantSearchGeneration: UInt64 = 0
  @EnvironmentObject var nav: Navigation
  @Environment(Router.self) var router
  @Environment(\.dismiss) var dismiss
  @State var selectedTab: PeerInfoTab
  @State var showMakePublicAlert = false
  @State var showMakePrivateSheet = false
  @State var showClearHistorySheet = false
  @State var selectedVisibilityParticipants: Set<Int64> = []
  @State var chat: Chat?
  @State var chatSubscription: AnyCancellable?
  @State var dialogNotificationSubscription: AnyCancellable?
  @State var isEditingInfo = false
  @State var draftTitle = ""
  @State var draftEmoji = ""
  @State var isEmojiPickerPresented = false
  @State var emojiPickerPresentationGeneration: UInt64 = 0
  @State var isSavingInfo = false
  @FocusState var isTitleFocused: Bool
  @State var notificationSelection: DialogNotificationSettingSelection
  @State private var notificationMutationGeneration: UInt64 = 0
  @State private var canChangeVisibility = false
  /// False when opened from a member list or another profile, so Message leads.
  let isOverOwnChat: Bool
  @AppStorage(DeveloperMode.key) private var developerMode = false
  @ObservedObject var globalNotifications = INUserSettings.current.notification
  @ObservedObject private var agentGrants = AgentGrantStore.shared
  @ObservedObject private var agentStore = AgentWorkStateStore.shared
  @State var currentDialog: Dialog?
  @State var threadsModel: PeerInfoThreadsModel?
  @State var managedBot: UserInfo?
  @State var showTranslationOptions = false
  @State var pushedInfoItem: SpaceChatItem?
  @State var showBotAccess = false
  @State var showOwnedBotSettings = false
  @State var botSettingsModel = IOSBotsSettingsModel()
  @State var pendingDestructiveAction: ChatDestructiveAction?
  @State var participantToRemove: UserInfo?
  @State var groupToRemove: UserGroup?

  @Environment(\.appDatabase) var database

  var currentChat: Chat? {
    chat ?? chatItem.chat
  }

  var currentChatId: Int64 {
    currentChat?.id ?? chatItem.chat?.id ?? chatItem.dialog.chatId ?? 0
  }

  var isPrivate: Bool {
    currentChat?.isPublic == false
  }

  var isDM: Bool {
    chatItem.peerId.isPrivate
  }

  var directMessageUsername: String? {
    guard let username = chatItem.userInfo?.user.username?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !username.isEmpty
    else { return nil }

    return username
  }

  var theme = ThemeManager.shared.selected

  var currentMemberRole: MemberRole? {
    spaceMembersViewModel.members
      .first(
        where: { $0.userId == Auth.shared.getCurrentUserId()
        }
      )?.role
  }

  var isOwnerOrAdmin: Bool {
    currentMemberRole == .owner || currentMemberRole == .admin
  }

  /// Anyone who can see a private thread may add people to it.
  var canAddParticipants: Bool {
    ChatParticipantPolicy.canAdd(chat: currentChat)
  }

  /// Mirrors `ensureCanManageChatParticipants` on the server: the chat's creator
  /// may always remove people; in a space, so may its owners and admins.
  var canManageParticipants: Bool {
    guard isPrivate else { return false }
    if let currentUserId = Auth.shared.getCurrentUserId(), currentChat?.createdBy == currentUserId {
      return true
    }
    return currentChat?.spaceId != nil && isOwnerOrAdmin
  }

  /// Mirrors the update-chat-visibility server contract: only the creator of a
  /// space thread, or a space owner/admin, may change its visibility.
  var canChangeChatVisibility: Bool {
    canChangeVisibility
  }

  private var visibilityPermissionKey: String {
    guard let currentChat else { return "none" }
    return [
      "\(Auth.shared.getCurrentUserId() ?? 0)",
      "\(currentChat.id)",
      "\(currentChat.spaceId ?? 0)",
      "\(currentChat.createdBy ?? 0)",
      currentMemberRole?.rawValue ?? "none",
    ].joined(separator: ":")
  }

  var isCurrentUserDirectParticipant: Bool {
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }
    return participantsWithMembersViewModel.participants.contains(where: { $0.user.id == currentUserId })
  }

  var isCurrentUserEffectiveParticipant: Bool {
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }
    return participantsWithMembersViewModel.effectiveUserIds.contains(currentUserId)
  }

  var isCurrentUserSpaceMemberWithPublicAccess: Bool {
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }
    return spaceMembersViewModel.members.contains(where: { member in
      member.userId == currentUserId && member.canAccessPublicChats
    })
  }

  var canEditChatInfo: Bool {
    if let canUpdateInfo = currentChat?.canUpdateInfo {
      return canUpdateInfo
    }

    guard !isDM else { return false }
    if currentChat?.isReplyThread == true, isOwnerOrAdmin {
      return true
    }
    if currentChat?.isPublic == true {
      return isCurrentUserSpaceMemberWithPublicAccess
    }
    if currentChat?.isReplyThread == true {
      return isCurrentUserEffectiveParticipant
    }
    return isCurrentUserDirectParticipant
  }

  var canClearHistory: Bool {
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }
    guard !isEditingInfo else { return false }

    if isDM {
      return true
    }

    guard let currentChat, currentChat.type == .thread else {
      return false
    }

    if currentChat.createdBy == currentUserId {
      return true
    }

    return currentChat.spaceId != nil && isOwnerOrAdmin
  }

  var canClearSpaceHistory: Bool {
    guard !isEditingInfo else { return false }
    return currentChat?.spaceId != nil && isOwnerOrAdmin
  }

  var chatTitle: String {
    currentChat?.humanReadableTitle ?? chatItem.chat?.humanReadableTitle ?? "Chat"
  }

  var isPresentedAsSheet: Bool {
    if isPresentedModally {
      return true
    }
    guard let presentedSheet = router.presentedSheet else { return false }
    guard case let .chatInfo(presentedChatItem) = presentedSheet else { return false }
    return presentedChatItem.id == chatItem.id
  }

  init(
    chatItem: SpaceChatItem,
    isPresentedModally: Bool = false,
    initiallyEditingInfo: Bool = false,
    isOverOwnChat: Bool = true
  ) {
    self.chatItem = chatItem
    self.isPresentedModally = isPresentedModally
    self.isOverOwnChat = isOverOwnChat
    _currentDialog = State(initialValue: chatItem.dialog)
    _isEditingInfo = State(initialValue: initiallyEditingInfo)
    _draftTitle = State(initialValue: initiallyEditingInfo ? (chatItem.chat?.title ?? "") : "")
    _draftEmoji = State(initialValue: initiallyEditingInfo ? (chatItem.chat?.emoji ?? "") : "")
    _participantsWithMembersViewModel = StateObject(wrappedValue: ChatParticipantsWithMembersViewModel(
      db: AppDatabase.shared,
      chatId: chatItem.chat?.id ?? 0
    ))

    _resources = EnvironmentStateObject { env in
      ChatInfoResourcesState(
        db: env.appDatabase,
        chatId: chatItem.chat?.id ?? chatItem.dialog.chatId ?? 0,
        peer: chatItem.peerId
      )
    }

    _spaceMembersViewModel = EnvironmentStateObject { env in
      SpaceMembersViewModel(db: env.appDatabase, spaceId: chatItem.chat?.spaceId ?? 0)
    }

    _spaceFullMembersViewModel = StateObject(wrappedValue: SpaceFullMembersViewModel(
      db: AppDatabase.shared,
      spaceId: chatItem.chat?.spaceId ?? 0
    ))
    _userGroupsViewModel = StateObject(wrappedValue: UserGroupsViewModel(
      db: AppDatabase.shared,
      spaceId: chatItem.chat?.spaceId ?? 0
    ))
    _notificationSelection = State(initialValue: chatItem.dialog.notificationSelection)

    let subject = PeerInfoSubject.resolve(
      peer: chatItem.peerId,
      chat: chatItem.chat,
      user: chatItem.userInfo?.user,
      currentUserId: Auth.shared.getCurrentUserId()
    )
    _selectedTab = State(initialValue: PeerInfoTab.tabs(for: subject).first ?? .media)
  }

  var body: some View {
    ScrollView(.vertical) {
      LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        VStack(spacing: 18) {
          chatInfoHeader
            .padding(.horizontal, 24)

          if isEditingInfo {
            editingCards
          } else {
            if !actions.isEmpty {
              actionRow
            }
            cards
            DeveloperIDsCard(entries: developerIDs)
              .padding(.horizontal, -16)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 18)

        if !isEditingInfo {
          Section {
            tabContent
              .padding(.top, 6)
              .padding(.bottom, 32)
          } header: {
            ChatInfoTabBar(tabs: availableTabs, selection: chatInfoTabSelection, title: { $0.title })
              .padding(.vertical, 8)
              .background(Color(uiColor: .systemGroupedBackground))
          }
        }
      }
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .coordinateSpace(name: "mainScroll")
    .onAppear {
      if isEditingInfo {
        startEditingChatInfo()
      }
      resources.updateChatId(currentChatId)
      resources.select(selectedTab)
      subscribeToChatUpdates()
      subscribeToDialogNotificationUpdates()
      startThreadsIfNeeded()
      Task {
        if !isDM {
          if let spaceId = chatItem.chat?.spaceId {
            await spaceMembersViewModel.refetchMembers()
            await userGroupsViewModel.loadIfNeeded()
            do {
              space = try await database.reader.read { db in
                try Space.fetchOne(db, id: spaceId)
              }
            } catch {
              Log.shared.error("Failed to fetch space: \(error)")
            }
          }
          await participantsWithMembersViewModel.refetchParticipants()
        }
      }
    }
    .onDisappear {
      resources.deactivate()
      threadsModel?.stop()
      chatSubscription?.cancel()
      chatSubscription = nil
      dialogNotificationSubscription?.cancel()
      dialogNotificationSubscription = nil
      emojiPickerPresentationGeneration &+= 1
      isTitleFocused = false
      isEmojiPickerPresented = false
      if !isSavingInfo {
        draftTitle = ""
        draftEmoji = ""
        isEditingInfo = false
      }
    }
    .interactiveDismissDisabled(isSavingInfo)
    .onChange(of: currentChatId) { _, chatId in
      resources.updateChatId(chatId)
      resources.select(selectedTab)
    }
    .onChange(of: selectedTab) { _, tab in resources.select(tab) }
    .onChange(of: availableTabs) { _, tabs in
      if !tabs.contains(selectedTab) { selectedTab = tabs.first ?? .media }
      startThreadsIfNeeded()
    }
    .task(id: chatItem.peerId) {
      if currentChatId <= 0 {
        do { _ = try await Api.realtime.send(.getChat(peer: chatItem.peerId)) }
        catch { resources.resolutionFailed = true }
      }
    }
    .task(id: botUserID) {
      guard let botUserID else { return }
      AgentGrantStore.shared.ensureLoaded(botUserID: botUserID)
      await AgentWorkStateStore.shared.loadDirectChatOutputModes(botUserID: botUserID)
    }
    .task(id: visibilityPermissionKey) {
      await refreshVisibilityPermission()
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("chatDeletedNotification"))
    ) { notification in
      if let chatId = notification.userInfo?["chatId"] as? Int64,
         chatId == currentChatId
      {
        if isPresentedAsSheet { dismiss() } else { nav.pop() }
      }
    }
    .sheet(
      isPresented: $isSearching,
      onDismiss: {
        cancelParticipantSearch()
        searchText = ""
      },
      content: { searchSheet }
    )
    .sheet(isPresented: $showMakePrivateSheet) {
      ChatVisibilityParticipantsSheet(
        spaceViewModel: spaceFullMembersViewModel,
        selectedParticipants: $selectedVisibilityParticipants,
        currentUserId: Auth.shared.getCurrentUserId(),
        onConfirm: {
          guard currentChatId != 0 else { return }
          var participantIds = selectedVisibilityParticipants
          if let currentUserId = Auth.shared.getCurrentUserId() {
            participantIds.insert(currentUserId)
          }
          Task {
            do {
              _ = try await Api.realtime.send(.updateChatVisibility(
                chatID: currentChatId,
                isPublic: false,
                participantIDs: participantIds.map(\.self)
              ))
              await participantsWithMembersViewModel.refetchParticipants()
              showMakePrivateSheet = false
            } catch {
              Log.shared.error("Failed to make chat private", error: error)
            }
          }
        },
        onCancel: {
          showMakePrivateSheet = false
        }
      )
    }
    .sheet(isPresented: $showClearHistorySheet) {
      IOSClearChatHistorySheet(
        peer: chatItem.peerId,
        chatTitle: chatTitle,
        spaceId: canClearSpaceHistory ? currentChat?.spaceId : nil
      )
    }
    .sheet(item: $managedBot) { bot in
      OwnedBotAccessSheet(bot: bot, participants: participantsWithMembersViewModel.participants)
    }
    .sheet(isPresented: $showTranslationOptions) {
      TranslationOptions(peer: chatItem.peerId)
    }
    .navigationDestination(item: $pushedInfoItem) { item in
      ChatInfoView(chatItem: item, isPresentedModally: false, isOverOwnChat: false)
    }
    .navigationDestination(isPresented: $showBotAccess) {
      if let bot = chatItem.userInfo {
        BotAccessView(bot: bot)
      }
    }
    .navigationDestination(isPresented: $showOwnedBotSettings) {
      if let botUserID {
        OwnedBotSettingsDestination(botUserID: botUserID, model: botSettingsModel)
      }
    }
    .alert("Make Thread Public", isPresented: $showMakePublicAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Make Public") {
        guard currentChatId != 0 else { return }
        Task {
          do {
            _ = try await Api.realtime.send(.updateChatVisibility(
              chatID: currentChatId,
              isPublic: true,
              participantIDs: []
            ))
            await participantsWithMembersViewModel.refetchParticipants()
          } catch {
            Log.shared.error("Failed to make chat public", error: error)
          }
        }
      }
    } message: {
      Text("Everyone in this space will be able to read and join it. People without access to public chats will lose access.")
    }
    .alert(
      pendingDestructiveAction?.title ?? "",
      isPresented: Binding(get: { pendingDestructiveAction != nil }, set: { if !$0 { pendingDestructiveAction = nil } }),
      presenting: pendingDestructiveAction
    ) { action in
      Button("Cancel", role: .cancel) {}
      Button(action.shortTitle, role: .destructive) { performDestructiveAction(action) }
    } message: { action in
      Text(action.confirmationMessage(chatTitle: chatTitle))
    }
    .confirmationDialog(
      "Remove from this thread?",
      isPresented: Binding(get: { participantToRemove != nil }, set: { if !$0 { participantToRemove = nil } }),
      titleVisibility: .visible,
      presenting: participantToRemove
    ) { participant in
      Button("Remove \(participant.user.shortDisplayName)", role: .destructive) { removeParticipant(participant) }
    } message: { participant in
      Text("\(participant.user.shortDisplayName) will lose access unless a group or the space still gives it.")
    }
    .confirmationDialog(
      "Remove group access?",
      isPresented: Binding(get: { groupToRemove != nil }, set: { if !$0 { groupToRemove = nil } }),
      titleVisibility: .visible,
      presenting: groupToRemove
    ) { group in
      Button("Remove \(group.name)", role: .destructive) { removeGroupParticipant(group) }
    } message: { group in
      Text("Members may still have access directly, through the parent thread, or through another group.")
    }
    .toolbar { toolbarContent }
  }

  // MARK: Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    if isEditingInfo {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          cancelEditingChatInfo()
        }
        .disabled(isSavingInfo)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(isSavingInfo ? "Saving…" : "Done") {
          saveChatInfo()
        }
        .disabled(!canSaveChatInfo || isSavingInfo)
      }
    } else {
      if isPresentedAsSheet {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
      if canEditFromToolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Edit") {
            editFromToolbar()
          }
        }
      }
      ToolbarItem(placement: .primaryAction) {
        moreMenu
      }
    }
  }

  private var moreMenu: some View {
    Menu {
      if botUserID != nil, managesBot {
        Button("Bot Settings", systemImage: "gearshape") { showOwnedBotSettings = true }
        Divider()
      }
      Button("Copy Link", systemImage: "link") { copyChatLink() }
        .disabled(currentChatId <= 0)
      if developerMode {
        if currentChatId > 0 {
          Button("Copy Chat ID", systemImage: "number") { DeveloperIDs.copy(currentChatId, label: "Chat ID") }
        }
        if case let .user(userId) = chatItem.peerId {
          Button("Copy User ID", systemImage: "number") { DeveloperIDs.copy(userId, label: "User ID") }
        }
      }
      Button("Translation", systemImage: "translate") { showTranslationOptions = true }
      if let nextPinned = nextPinnedState {
        Divider()
        Button(nextPinned ? "Pin" : "Unpin", systemImage: nextPinned ? "pin" : "pin.slash") {
          updatePinned(nextPinned)
        }
      }
      if canClearHistory || destructiveAction != nil {
        Divider()
        if canClearHistory {
          Button("Delete History…", systemImage: "trash", role: .destructive) {
            showClearHistorySheet = true
          }
        }
        if let destructiveAction {
          Button(destructiveAction.title + "…", systemImage: destructiveAction.systemImage, role: .destructive) {
            pendingDestructiveAction = destructiveAction
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .accessibilityLabel("More")
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
      tile(subject.isThread ? "Open" : "Message", systemImage: subject.isThread ? "bubble.left.and.bubble.right" : "message") {
        openChat(chatItem.peerId)
      }
    case .search:
      EmptyView()
    case .notifications:
      notificationsButton
    case .follow:
      tile(isFollowing ? "Following" : "Follow", systemImage: isFollowing ? "checkmark.circle" : "eye") {
        toggleFollow()
      }
      .accessibilityValue(isFollowing ? "On" : "Off")
      .accessibilityHint(isFollowing ? "Stops surfacing this thread for every new message" : "Surfaces this thread for every new message")
    case .output:
      if let botUserID {
        AgentOutputModeSection(peer: chatItem.peerId, botUserID: botUserID, style: .actionTile)
      }
    case .share:
      tile("Share", systemImage: "person.crop.circle.badge.plus") {
        showBotAccess = true
      }
      .accessibilityHint("Choose who can message this bot")
    case .addMembers:
      tile("Add", systemImage: "person.badge.plus") {
        isSearching = true
      }
      .accessibilityHint("Adds people or groups to this thread")
    }
  }

  private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      action()
    } label: {
      PeerInfoActionTile(title, systemImage: systemImage)
    }
    .buttonStyle(PeerInfoActionTileButtonStyle())
  }

  /// Tap mutes or unmutes at once; long-press for every choice.
  private var notificationsButton: some View {
    let notifications = PeerInfoNotificationsPresentation(selection: notificationSelection, globalMode: globalNotifications.mode)
    return Menu {
      DialogNotificationSettingsMenuContent(
        selection: notificationSelectionBinding,
        globalMode: globalNotifications.mode
      )
    } label: {
      PeerInfoActionTile(
        notifications.isMuted ? "Unmute" : "Mute",
        systemImage: notifications.isMuted ? "bell.slash.fill" : "bell",
        detail: notifications.effectiveMode == .mentions || notifications.effectiveMode == .onlyMentions ? "Mentions" : nil,
        isHighlighted: notifications.isMuted
      )
    } primaryAction: {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      let next = notifications.quickToggleSelection
      updateNotificationSelection(next)
      let nextState = PeerInfoNotificationsPresentation(selection: next, globalMode: globalNotifications.mode)
      ToastManager.shared.showToast(
        nextState.isMuted ? "Muted" : "Unmuted",
        type: .success,
        systemImage: nextState.isMuted ? "bell.slash.fill" : "bell.fill"
      )
    }
    .buttonStyle(PeerInfoActionTileButtonStyle())
    .accessibilityLabel(notifications.isMuted ? "Unmute" : "Mute")
    .accessibilityValue(notifications.accessibilityValue)
    .accessibilityHint("Double-tap to switch. Touch and hold for more options.")
  }

  // MARK: Cards

  @ViewBuilder
  private var cards: some View {
    switch subject.kind {
    case .person:
      if let user = chatItem.userInfo?.user {
        PeerInfoIOSPersonCard(user: user)
      }
    case .bot:
      if let bot = chatItem.userInfo {
        PeerInfoIOSBotCard(bot: bot) { ownerId in
          pushInfo(for: .user(id: ownerId))
        }
      }
    case .thread, .subthread:
      PeerInfoIOSPlaceCard(
        subject: subject,
        space: space,
        parent: subject.parentChatId.flatMap { ObjectCache.shared.getChat(id: $0) },
        onOpenParent: openParent
      )
    case .selfChat:
      EmptyView()
    }
  }

  /// Visibility, while editing a space thread.
  @ViewBuilder
  private var editingCards: some View {
    if let chat = currentChat, chat.spaceId != nil, chat.parentChatId == nil {
      PeerInfoIOSCard(
        "Visibility",
        footer: chat.isPublic == true
          ? "Everyone in this space can read and join this thread."
          : canChangeChatVisibility
            ? "Only the people and groups you add can read this thread."
            : "Only the people and groups added can read this thread. The creator or a space admin can change this."
      ) {
        HStack {
          Label(chat.isPublic == true ? "Public" : "Private", systemImage: chat.isPublic == true ? "person.2" : "lock")
            .frame(maxWidth: .infinity, alignment: .leading)
          if canChangeChatVisibility {
            Button(chat.isPublic == true ? "Make Private" : "Make Public") {
              if chat.isPublic == true {
                selectedVisibilityParticipants = Auth.shared.getCurrentUserId().map { [$0] } ?? []
                showMakePrivateSheet = true
              } else {
                showMakePublicAlert = true
              }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
    }
  }

  // MARK: Tabs

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
    case .members:
      PeerInfoIOSMembersList(
        participants: participantsWithMembersViewModel,
        roles: memberRoles,
        isPublic: currentChat?.isPublic == true,
        canAdd: canAddParticipants,
        canRemove: canManageParticipants,
        onAdd: { isSearching = true },
        onOpen: { pushInfo(for: .user(id: $0.user.id)) },
        onMessage: { openChat(.user(id: $0.user.id)) },
        onManageBot: { managedBot = $0 },
        onRemove: { participantToRemove = $0 },
        onRemoveGroup: { groupToRemove = $0 }
      )
    case .threads:
      if let threadsModel {
        PeerInfoIOSThreadsList(
          model: threadsModel,
          emptyMessage: subject.isThread ? "No subthreads yet." : "No shared threads yet.",
          onOpen: { openChat($0.peer) },
          onShowInfo: { pushInfo(for: $0.peer) }
        )
      } else {
        resourceResolutionView
      }
    case .media:
      if let model = resources.media {
        MediaTabView(mediaViewModel: model, onShowInChat: showMessageInChat)
      } else {
        resourceResolutionView
      }
    case .voice:
      if let model = resources.voice {
        VoiceMemosTabView(voiceMemosViewModel: model, onShowInChat: showMessageInChat)
      } else {
        resourceResolutionView
      }
    case .files:
      if let model = resources.files {
        DocumentsTabView(
          documentsViewModel: model,
          peerUserId: chatItem.dialog.peerUserId,
          peerThreadId: currentChatId > 0 ? currentChatId : nil,
          onShowInChat: showMessageInChat
        )
      } else {
        resourceResolutionView
      }
    case .links:
      if let model = resources.links {
        LinksTabView(linksViewModel: model, onShowInChat: showMessageInChat)
      } else {
        resourceResolutionView
      }
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

  // MARK: Navigation

  /// Leaves chat info for a chat: closes the sheet and opens it in the app.
  private func openChat(_ peer: Peer) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if isPresentedAsSheet { dismiss() }
    // The router draws both layouts; the legacy `nav` path is not shown, so a push there
    // only closed the sheet.
    router.resetTransientPresentation()
    router.openPrimaryDestination(.chat(peer: peer))
  }

  /// Opens another peer's info on top of this one, without leaving the sheet.
  private func pushInfo(for peer: Peer) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if let item = FullChatViewModel.cachedChatItem(peer: peer) {
      pushedInfoItem = item
    } else {
      // No local chat yet: the chat itself is the profile until it loads.
      openChat(peer)
    }
  }

  private func openParent() {
    guard let parentChatId = subject.parentChatId else { return }
    let parentPeer = ObjectCache.shared.getChat(id: parentChatId)?.deepLinkPeer ?? .thread(id: parentChatId)
    if isPresentedAsSheet { dismiss() }
    if let messageId = subject.parentMessageId, router.tracksHistory {
      router.resetTransientPresentation()
      router.openPrimaryDestination(.chatMessage(peer: parentPeer, messageID: messageId))
    } else {
      openChat(parentPeer)
    }
  }

  private var resourceResolutionView: some View {
    VStack(spacing: 8) {
      if resources.resolutionFailed {
        Text("Couldn't load chat.").foregroundStyle(.secondary)
        Button("Retry") {
          Task {
            resources.resolutionFailed = false
            do { _ = try await Api.realtime.send(.getChat(peer: chatItem.peerId)) }
            catch { resources.resolutionFailed = true }
          }
        }
      } else {
        ProgressView()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  @MainActor
  func subscribeToChatUpdates() {
    guard chatSubscription == nil else { return }
    chatSubscription = ValueObservation.tracking { [peer = chatItem.peerId] db in
      try Chat.getByPeerId(db: db, peerId: peer)
    }
    .publisher(in: database.dbWriter, scheduling: .async(onQueue: .main))
    .sink(
      receiveCompletion: { completion in
        if case let .failure(error) = completion {
          Log.shared.error("Failed to observe chat info", error: error)
        }
      },
      receiveValue: { updatedChat in chat = updatedChat }
    )
  }

  @MainActor
  private func subscribeToDialogNotificationUpdates() {
    guard dialogNotificationSubscription == nil else { return }

    database.warnIfInMemoryDatabaseForObservation("ChatInfoView.dialogNotificationSettings")
    dialogNotificationSubscription = ValueObservation
      .tracking { [chatPeer = chatItem.peerId] db in
        try Dialog.get(peerId: chatPeer).fetchOne(db)
      }
      .publisher(in: database.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { completion in
          if case let .failure(error) = completion {
            Log.shared.error("Dialog notification settings observation failed", error: error)
          }
        },
        receiveValue: { dialog in
          notificationSelection = dialog?.notificationSelection ?? .global
          currentDialog = dialog
        }
      )
  }

  private func updateNotificationSelection(_ selection: DialogNotificationSettingSelection) {
    guard selection != notificationSelection else { return }
    let previousSelection = notificationSelection
    notificationSelection = selection
    notificationMutationGeneration &+= 1
    let generation = notificationMutationGeneration

    Task(priority: .userInitiated) {
      do {
        _ = try await Api.realtime.send(.updateDialogNotificationSettings(
          peerId: chatItem.peerId,
          selection: selection
        ))
      } catch is CancellationError {
        return
      } catch let error as URLError where error.code == .cancelled {
        return
      } catch {
        Log.shared.error("Failed to update dialog notification settings", error: error)
        await MainActor.run {
          guard notificationMutationGeneration == generation,
                notificationSelection == selection
          else { return }
          notificationSelection = previousSelection
        }
      }
    }
  }

  @MainActor
  private func refreshVisibilityPermission() async {
    guard let currentChat,
          currentChat.type == .thread,
          let spaceId = currentChat.spaceId,
          let currentUserId = Auth.shared.getCurrentUserId()
    else {
      canChangeVisibility = false
      return
    }

    let membership = try? await database.reader.read { db in
      try Member
        .filter(Member.Columns.spaceId == spaceId)
        .filter(Member.Columns.userId == currentUserId)
        .fetchOne(db)
    }
    guard !Task.isCancelled else { return }
    canChangeVisibility = ChatVisibilityPolicy.canChange(
      chat: currentChat,
      currentUserId: currentUserId,
      membership: membership
    )
  }

  private var notificationSelectionBinding: Binding<DialogNotificationSettingSelection> {
    Binding(
      get: { notificationSelection },
      set: { updateNotificationSelection($0) }
    )
  }

  private var chatInfoTabSelection: Binding<PeerInfoTab> {
    Binding(
      get: { selectedTab },
      set: { newTab in
        guard newTab != selectedTab else { return }

        if isEditingInfo {
          guard !isSavingInfo else { return }
          cancelEditingChatInfo()
        }

        resources.select(newTab)
        selectedTab = newTab
      }
    )
  }
}

private struct IOSClearChatHistorySheet: View {
  let peer: Peer
  let chatTitle: String
  let spaceId: Int64?

  @Environment(\.dismiss) private var dismiss
  @State private var range: IOSClearChatHistoryRange = .keep(90)
  @State private var customDays = 90
  @State private var deleteReplyThreads = false
  @State private var clearSpace = false
  @State private var isSubmitting = false
  @State private var showClearConfirmation = false

  var body: some View {
    NavigationStack {
      Form {
        Section(chatTitle) {
          Picker("Range", selection: $range) {
            ForEach(IOSClearChatHistoryRange.allCases) { range in
              Text(range.title).tag(range)
            }
          }

          if range == .custom {
            Stepper("Keep last \(customDays) days", value: $customDays, in: 1 ... 36_500)
          }

          Toggle("Delete reply threads", isOn: $deleteReplyThreads)

          if spaceId != nil {
            Toggle("Clear all chats in this space", isOn: $clearSpace)
          }
        }
      }
      .navigationTitle("Delete History")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isSubmitting)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Delete", role: .destructive) {
            showClearConfirmation = true
          }
          .disabled(isSubmitting)
        }
      }
    }
    .presentationDetents([.medium])
    .alert("Delete history for everyone?", isPresented: $showClearConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete History", role: .destructive) {
        clearHistory()
      }
    } message: {
      Text(clearConfirmationMessage)
    }
  }

  private var keepLastDays: Int32 {
    switch range {
      case .all:
        0
      case let .keep(days):
        Int32(days)
      case .custom:
        Int32(customDays)
    }
  }

  private var clearConfirmationMessage: String {
    let target = clearSpace && spaceId != nil ? "all chats in this space" : "this chat"
    let rangeText = keepLastDays == 0 ? "all history" : "history older than \(keepLastDays) days"
    return "This will delete \(rangeText) from \(target) for everyone. You will have 5 seconds to undo before it starts."
  }

  @MainActor
  private func clearHistory() {
    guard !isSubmitting else { return }
    let selectedKeepLastDays = keepLastDays
    let shouldDeleteReplyThreads = deleteReplyThreads
    let selectedSpaceId = clearSpace ? spaceId : nil
    isSubmitting = true

    DelayedDestructiveActionScheduler.shared.cancelAll()
    let token = DelayedDestructiveActionScheduler.shared.schedule(
      onPerforming: {
        ToastManager.shared.hideToast()
        ToastManager.shared.showToast("Deleting history...", type: .loading, systemImage: "trash")
      },
      action: {
        if let selectedSpaceId {
          _ = try await Api.realtime.send(.clearChatHistory(
            spaceId: selectedSpaceId,
            keepLastDays: selectedKeepLastDays,
            deleteReplyThreads: shouldDeleteReplyThreads
          ))
        } else {
          _ = try await Api.realtime.send(.clearChatHistory(
            peerId: peer,
            keepLastDays: selectedKeepLastDays,
            deleteReplyThreads: shouldDeleteReplyThreads
          ))
        }
      },
      onSuccess: {
        ToastManager.shared.hideToast()
        ToastManager.shared.showToast("History deleted", type: .success, systemImage: "checkmark.circle.fill")
      },
      onFailure: { _ in
        ToastManager.shared.hideToast()
        ToastManager.shared.showToast(
          "Failed to delete history",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    )

    ToastManager.shared.showUndoCountdown("Deleting history") {
      Task { @MainActor in
        if DelayedDestructiveActionScheduler.shared.cancel(token) {
          ToastManager.shared.hideToast()
          ToastManager.shared.showToast("Delete history canceled", type: .info, systemImage: "arrow.uturn.backward")
        }
      }
    }
    dismiss()
  }
}

private enum IOSClearChatHistoryRange: Hashable, Identifiable, CaseIterable {
  case all
  case keep(Int)
  case custom

  static let allCases: [IOSClearChatHistoryRange] = [
    .keep(90),
    .keep(7),
    .keep(30),
    .all,
    .custom,
  ]

  var id: String {
    switch self {
      case .all:
        "all"
      case let .keep(days):
        "keep-\(days)"
      case .custom:
        "custom"
    }
  }

  var title: String {
    switch self {
      case .all:
        "All history"
      case let .keep(days):
        "Keep last \(days) days"
      case .custom:
        "Custom"
    }
  }
}

struct ParticipantAvatarView: UIViewRepresentable {
  let userInfo: UserInfo
  let size: CGFloat
  /// Replaces opening the photo when set.
  var onTap: (() -> Void)? = nil

  func makeUIView(context: Context) -> UserAvatarView {
    let view = UserAvatarView()
    view.isUserInteractionEnabled = true
    let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
    tapGesture.delegate = context.coordinator
    view.addGestureRecognizer(tapGesture)
    return view
  }

  func updateUIView(_ uiView: UserAvatarView, context: Context) {
    uiView.configure(with: userInfo, size: size)
    context.coordinator.userInfo = userInfo
    context.coordinator.avatarView = uiView
    context.coordinator.onTap = onTap
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var userInfo: UserInfo?
    weak var avatarView: UserAvatarView?
    var onTap: (() -> Void)?

    @objc func handleTap() {
      if let onTap {
        onTap()
        return
      }
      guard let userInfo, let avatarView else { return }

      let sourceImage = avatarView.currentImage() ?? snapshotImage(from: avatarView)
      guard let resolved = resolveAvatarURL(for: userInfo, fallbackImage: sourceImage) else { return }

      let sourceCornerRadius = max(
        avatarView.layer.cornerRadius,
        min(avatarView.bounds.width, avatarView.bounds.height) / 2
      )
      let imageViewer = MediaGalleryViewController(
        imageURL: resolved.url,
        sourceView: avatarView,
        sourceImage: sourceImage,
        sourceCornerRadius: sourceCornerRadius
      )
      if resolved.isTemporary {
        let temporaryUrl = resolved.url
        imageViewer.onDismiss = {
          try? FileManager.default.removeItem(at: temporaryUrl)
        }
      }

      findViewController(from: avatarView)?.present(imageViewer, animated: false)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }

    func resolveAvatarURL(
      for userInfo: UserInfo,
      fallbackImage: UIImage?
    ) -> (url: URL, isTemporary: Bool)? {
      if let localUrl = userInfo.user.getLocalURL(),
         FileManager.default.fileExists(atPath: localUrl.path)
      {
        return (localUrl, false)
      }

      if let localFileUrl = userInfo.profilePhoto?.first?.getLocalURL(),
         FileManager.default.fileExists(atPath: localFileUrl.path)
      {
        return (localFileUrl, false)
      }

      if let remoteUrl = userInfo.user.getRemoteURL() {
        return (remoteUrl, false)
      }

      if let remoteFileUrl = userInfo.profilePhoto?.first?.getRemoteURL() {
        return (remoteFileUrl, false)
      }

      guard let fallbackImage, let temporaryUrl = cacheTemporaryImage(fallbackImage) else { return nil }
      return (temporaryUrl, true)
    }

    func cacheTemporaryImage(_ image: UIImage) -> URL? {
      guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("avatar-\(UUID().uuidString).jpg")
      do {
        try data.write(to: url, options: [.atomic])
        return url
      } catch {
        Log.shared.error("Failed to cache avatar snapshot", error: error)
        return nil
      }
    }

    func snapshotImage(from view: UIView) -> UIImage? {
      guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
      let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
      return renderer.image { context in
        view.layer.render(in: context.cgContext)
      }
    }

    func findViewController(from view: UIView) -> UIViewController? {
      var responder: UIResponder? = view
      while let nextResponder = responder?.next {
        if let viewController = nextResponder as? UIViewController {
          return viewController
        }
        responder = nextResponder
      }
      return nil
    }
  }
}

@MainActor
private final class ChatInfoResourcesState: ObservableObject {
  @Published private(set) var media: ChatMediaViewModel?
  @Published private(set) var files: ChatDocumentsViewModel?
  @Published private(set) var voice: ChatVoiceMemosViewModel?
  @Published private(set) var links: ChatLinksViewModel?
  @Published var resolutionFailed = false
  private let db: AppDatabase
  private let peer: Peer
  private var chatId: Int64 = 0

  init(db: AppDatabase, chatId: Int64, peer: Peer) {
    self.db = db
    self.peer = peer
    updateChatId(chatId)
  }

  func updateChatId(_ chatId: Int64) {
    guard chatId > 0, self.chatId != chatId else { return }
    self.chatId = chatId
    resolutionFailed = false
    deactivate()
    media = nil
    files = nil
    voice = nil
    links = nil
  }

  func deactivate() {
    media?.deactivate()
    files?.deactivate()
    voice?.deactivate()
    links?.deactivate()
  }

  func select(_ tab: PeerInfoTab) {
    if tab != .media {
      media?.deactivate()
    }
    if tab != .files {
      files?.deactivate()
    }
    if tab != .voice {
      voice?.deactivate()
    }
    if tab != .links {
      links?.deactivate()
    }
    guard chatId > 0 else { return }
    switch tab {
      case .media:
        if media == nil {
          media = ChatMediaViewModel(db: db, chatId: chatId, peer: peer, excludeStickerMedia: true)
        }
      case .files:
        if files == nil {
          files = ChatDocumentsViewModel(db: db, chatId: chatId, peer: peer)
        }
      case .voice:
        if voice == nil {
          voice = ChatVoiceMemosViewModel(db: db, chatId: chatId, peer: peer)
        }
      case .links:
        if links == nil {
          links = ChatLinksViewModel(db: db, chatId: chatId, peer: peer)
        }
      default: break
    }
  }
}

// MARK: - Peer info model

extension ChatInfoView {
  var subject: PeerInfoSubject {
    PeerInfoSubject.resolve(
      peer: chatItem.peerId,
      chat: currentChat,
      user: chatItem.userInfo?.user,
      currentUserId: Auth.shared.getCurrentUserId()
    )
  }

  var availableTabs: [PeerInfoTab] {
    PeerInfoTab.tabs(for: subject)
  }

  /// Raw IDs for Developer Mode's card.
  var developerIDs: [DeveloperIDs.Entry] {
    var entries: [DeveloperIDs.Entry] = []
    if currentChatId > 0 { entries.append(.init(label: "Chat ID", id: currentChatId)) }
    if case let .user(userId) = chatItem.peerId { entries.append(.init(label: "User ID", id: userId)) }
    return entries
  }

  var botUserID: Int64? {
    guard let user = chatItem.userInfo?.user, user.bot else { return nil }
    return user.id
  }

  /// The viewer owns or admins this bot.
  var managesBot: Bool {
    guard let botUserID else { return false }
    return AgentGrantStore.shared.ownedGrants(botUserID: botUserID) != nil
  }

  var actions: [PeerInfoAction] {
    PeerInfoAction.actions(
      for: subject,
      context: PeerInfoActionContext(
        isOverOwnChat: isOverOwnChat,
        supportsInChatSearch: false,
        canAddMembers: canAddParticipants && !isDM,
        canShareBot: managesBot,
        offersOutputMode: botUserID.map { AgentWorkStateStore.shared.offersOutputMode(botUserID: $0) } ?? false
      )
    )
  }

  var isFollowing: Bool {
    currentDialog?.isFollowingThread == true
  }

  var memberRoles: [Int64: MemberRole] {
    Dictionary(spaceMembersViewModel.members.map { ($0.userId, $0.role) }, uniquingKeysWith: { first, _ in first })
  }

  /// Edit covers a thread's name and icon, and a managed bot's profile.
  var canEditFromToolbar: Bool {
    switch subject.kind {
    case .thread, .subthread: canEditChatInfo
    case .bot: managesBot
    case .person, .selfChat: false
    }
  }

  func editFromToolbar() {
    switch subject.kind {
    case .thread, .subthread:
      startEditingChatInfo()
    case .bot:
      showOwnedBotSettings = true
    case .person, .selfChat:
      break
    }
  }

  var destructiveAction: ChatDestructiveAction? {
    ChatDestructiveActionResolver.action(peer: chatItem.peerId, chat: currentChat)
  }

  var nextPinnedState: Bool? {
    guard let dialog = currentDialog else { return nil }
    if dialog.pinned == true { return false }
    let isInboxEligible = dialog.open && dialog.archived != true && dialog.chatListHidden != true
    return isInboxEligible ? true : nil
  }

  func updatePinned(_ pinned: Bool) {
    let peer = chatItem.peerId
    Task(priority: .userInitiated) {
      do {
        _ = try await Api.realtime.send(.updateDialogOrder(peerId: peer, pinned: pinned))
        ToastManager.shared.showToast(pinned ? "Pinned" : "Unpinned", type: .success, systemImage: pinned ? "pin.fill" : "pin.slash")
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to update pin state", error: error)
        ToastManager.shared.showToast("Couldn’t update pin", type: .error, systemImage: "exclamationmark.triangle")
      }
    }
  }

  func toggleFollow() {
    let peer = chatItem.peerId
    let follow = !isFollowing
    Task(priority: .userInitiated) {
      do {
        _ = try await Api.realtime.send(.updateDialogFollowMode(peerId: peer, selection: follow ? .following : .unfollowed))
        ToastManager.shared.showToast(
          follow ? "Following" : "Unfollowed",
          description: follow
            ? "New messages will appear in Open Chats."
            : "Only mentions and replies can bring this thread back.",
          type: .success,
          systemImage: follow ? "eye.fill" : "eye.slash.fill"
        )
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to update follow state", error: error)
        ToastManager.shared.showToast("Couldn’t update follow", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  func copyChatLink() {
    guard currentChatId > 0, let url = InlineDeepLink.chat(id: currentChatId).webURL else {
      ToastManager.shared.showToast("Couldn’t copy link", type: .error, systemImage: "exclamationmark.triangle")
      return
    }
    PeerInfoIOSPasteboard.copy(url.absoluteString, toast: "Copied link")
  }

  func removeParticipant(_ userInfo: UserInfo) {
    guard currentChatId != 0 else { return }
    let chatId = currentChatId
    Task {
      do {
        try await Api.realtime.send(.removeChatParticipant(chatID: chatId, userID: userInfo.user.id))
        await participantsWithMembersViewModel.refetchParticipants()
      } catch {
        Log.shared.error("Failed to remove participant", error: error)
        ToastManager.shared.showToast("Couldn’t remove \(userInfo.user.shortDisplayName)", type: .error, systemImage: "exclamationmark.triangle")
      }
    }
  }

  /// Deletes or leaves the thread with the same account fencing as macOS, so
  /// an account switch mid-request never touches the wrong local data.
  func performDestructiveAction(_ action: ChatDestructiveAction) {
    pendingDestructiveAction = nil
    let peer = chatItem.peerId
    let auth = Auth.shared.handle
    let token: AuthAccountMutationToken
    do {
      token = try auth.beginAccountMutation()
    } catch {
      ToastManager.shared.showToast(action.failureTitle, type: .error, systemImage: "exclamationmark.triangle")
      return
    }
    let writer = database.dbWriter
    Task(priority: .userInitiated) {
      do {
        switch action {
        case .delete:
          _ = try await Api.realtime.send(.deleteChat(peerId: peer), expectedAccount: token)
        case .leave:
          guard let chatId = peer.asThreadId() else { return }
          _ = try await Api.realtime.send(.removeChatParticipant(chatID: chatId, userID: token.userID), expectedAccount: token)
          try await Chat.deleteFromLocalDatabase(peerId: peer, databaseWriter: writer, auth: auth, accountToken: token)
        }
        try auth.validateAccountMutation(token)
        ToastManager.shared.showToast(action.successTitle, type: .success, systemImage: action.systemImage)
        if isPresentedAsSheet { dismiss() }
        router.resetTransientPresentation()
      } catch {
        Log.shared.error(action.failureTitle, error: error)
        guard (try? auth.validateAccountMutation(token)) != nil else { return }
        ToastManager.shared.showToast(action.failureTitle, type: .error, systemImage: "exclamationmark.triangle")
      }
    }
  }
}

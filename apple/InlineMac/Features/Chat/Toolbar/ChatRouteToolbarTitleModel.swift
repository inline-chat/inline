import Auth
import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import Observation
import RealtimeV2

@MainActor
@Observable
final class ChatRouteToolbarTitleModel {
  enum Status: Equatable {
    case none
    case text(String)
    case typing(String)

    var text: String? {
      switch self {
      case .none:
        nil
      case let .text(text), let .typing(text):
        text
      }
    }

    var isTyping: Bool {
      if case .typing = self {
        return true
      }
      return false
    }
  }

  struct ParentThread: Equatable {
    let peer: Peer
    let title: String
  }

  private struct Snapshot {
    let chat: Chat?
    let userInfo: UserInfo?
    let parentChat: Chat?
    let parentUserInfo: UserInfo?
    let parentPeerUserId: Int64?
    let anchorText: String?
  }

  let peer: Peer

  var title: String
  var windowTitle: String
  var iconPeer: ChatIcon.PeerType?
  var parentThread: ParentThread?
  var status: Status = .none
  var canRename = false
  var isEditingTitle = false
  var isSavingTitle = false
  var titleDraft = ""
  var emojiDraft = ""

  @ObservationIgnored private let db: AppDatabase
  @ObservationIgnored private let log = Log.scoped("ChatRouteToolbarTitle")
  @ObservationIgnored private var loadedChat: Chat?
  @ObservationIgnored private var loadedParentChat: Chat?
  @ObservationIgnored private var loadedParentUserInfo: UserInfo?
  @ObservationIgnored private var loadedParentPeerUserId: Int64?
  @ObservationIgnored private var loadedAnchorText: String?
  @ObservationIgnored private var loadedSpace: Space?
  @ObservationIgnored private var loadedUserInfo: UserInfo?
  @ObservationIgnored private var contextSpaceId: Int64?
  @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
  @ObservationIgnored private var parentChatCancellable: AnyCancellable?
  @ObservationIgnored private var spaceCancellable: AnyDatabaseCancellable?
  @ObservationIgnored private var observedParentChatId: Int64?
  @ObservationIgnored private var observedSpaceId: Int64?
  @ObservationIgnored private var snapshotTask: Task<Void, Never>?
  @ObservationIgnored private var renameEligibilityTask: Task<Void, Never>?
  @ObservationIgnored private var displayedConnectionState: RealtimeConnectionState? {
    didSet {
      guard oldValue != displayedConnectionState else { return }
      refreshStatus()
    }
  }

  init(peer: Peer, db: AppDatabase, contextSpaceId: Int64? = nil) {
    let initialTitle = peer.isThread ? "Chat" : "Direct Message"
    self.peer = peer
    self.db = db
    self.contextSpaceId = contextSpaceId
    title = initialTitle
    windowTitle = initialTitle
    titleDraft = initialTitle

    loadInitialSnapshot()
    observe()
    sync()
    loadSnapshot()
    refreshRenameEligibility()
  }

  deinit {
    snapshotTask?.cancel()
    renameEligibilityTask?.cancel()
    parentChatCancellable?.cancel()
    spaceCancellable?.cancel()
    cancellables.removeAll()
  }

  func startEditingTitle() {
    guard canRename else { return }
    guard peer.isThread else { return }
    guard !isSavingTitle else { return }
    titleDraft = title
    emojiDraft = resolvedEmoji() ?? ""
    isEditingTitle = true
  }

  func cancelEditingTitle() {
    titleDraft = title
    emojiDraft = resolvedEmoji() ?? ""
    isEditingTitle = false
  }

  func commitTitleEdit() {
    guard isEditingTitle else { return }
    guard !isSavingTitle else { return }

    let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      cancelEditingTitle()
      return
    }

    guard let chatId = peer.asThreadId() else {
      cancelEditingTitle()
      return
    }

    let nextEmoji = Self.normalizedEmoji(emojiDraft)
    let shouldUpdateTitle = trimmedTitle != title
    let shouldUpdateEmoji = nextEmoji != resolvedEmoji()

    if !shouldUpdateTitle && !shouldUpdateEmoji {
      cancelEditingTitle()
      return
    }

    if shouldUpdateTitle {
      title = trimmedTitle
      titleDraft = trimmedTitle
      refreshWindowTitle()
    }
    emojiDraft = nextEmoji ?? ""
    updateIconPeer(
      title: shouldUpdateTitle ? trimmedTitle : nil,
      emoji: nextEmoji,
      updatesEmoji: shouldUpdateEmoji
    )
    isEditingTitle = false
    isSavingTitle = true

    Task { [weak self] in
      guard let self else { return }
      defer { isSavingTitle = false }

      do {
        _ = try await Api.realtime.send(.updateChatInfo(
          chatID: chatId,
          title: shouldUpdateTitle ? trimmedTitle : nil,
          emoji: shouldUpdateEmoji ? (nextEmoji ?? "") : nil
        ))
      } catch {
        log.error("Failed to update chat info", error: error)
      }
    }
  }

  func update(contextSpaceId: Int64?) {
    guard self.contextSpaceId != contextSpaceId else { return }
    self.contextSpaceId = contextSpaceId
    updateSpaceSubscription()
    refreshWindowTitle()
  }

  private func observe() {
    ComposeActions.shared.$actions
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshStatus()
      }
      .store(in: &cancellables)

    if let userId = peer.asUserId() {
      ObjectCache.shared.getUserPublisher(id: userId)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          self?.sync()
        }
        .store(in: &cancellables)
    }

    if let chatId = peer.asThreadId() {
      ObjectCache.shared.getChatPublisher(id: chatId)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          self?.sync()
          self?.refreshRenameEligibility()
        }
        .store(in: &cancellables)
    }

    let stateObject = Api.realtime.stateObject
    displayedConnectionState = stateObject.displayedConnectionState

    stateObject.displayedConnectionStatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.displayedConnectionState = state
      }
      .store(in: &cancellables)
  }

  private func sync() {
    title = resolvedTitle()
    if !isEditingTitle {
      titleDraft = title
      emojiDraft = resolvedEmoji() ?? ""
    }
    iconPeer = resolvedIconPeer()
    parentThread = resolvedParentThread()
    updateParentChatSubscription()
    updateSpaceSubscription()
    refreshWindowTitle()
    refreshStatus()
  }

  private func refreshWindowTitle() {
    windowTitle = resolvedWindowTitle()
  }

  private func refreshStatus() {
    status = resolvedStatus()
  }

  private func resolvedWindowTitle() -> String {
    guard let space = loadedSpace else { return title }
    return "\(space.displayName) - \(title)"
  }

  private func resolvedTitle() -> String {
    if let user = resolvedUserInfo()?.user {
      return user.isCurrentUser() ? "Saved Messages" : user.displayName
    }

    if let chat = resolvedChat() {
      return ReplyThreadTitleFallback.title(for: chat, anchorText: loadedAnchorText)
    }

    return peer.isThread ? "Chat" : "Direct Message"
  }

  private func resolvedIconPeer() -> ChatIcon.PeerType? {
    if let user = resolvedUserInfo() {
      return user.user.isCurrentUser() ? .savedMessage(user.user) : .user(user)
    }

    if let chat = resolvedChat() {
      return .chat(chat)
    }

    return nil
  }

  private func resolvedEmoji() -> String? {
    Self.normalizedEmoji(resolvedChat()?.emoji)
  }

  private func updateIconPeer(title: String?, emoji: String?, updatesEmoji: Bool) {
    guard var chat = resolvedChat() else { return }
    if let title {
      chat.title = title
    }
    if updatesEmoji {
      chat.emoji = emoji
    }
    loadedChat = chat
    iconPeer = .chat(chat)
  }

  private func resolvedStatus() -> Status {
    if let displayedConnectionState {
      return .text(displayedConnectionState.title.lowercased())
    }

    if peer.isPrivate {
      if let typingText = ComposeActions.shared.getTypingDisplayText(for: peer), !typingText.isEmpty {
        return .typing(typingText)
      }

      if let action = ComposeActions.shared.getComposeAction(for: peer)?.action, action != .typing {
        return .text(action.toHumanReadable())
      }

      if let localTime = resolvedLocalTime() {
        return .text(localTime)
      }

      return .none
    }

    if let typingText = ComposeActions.shared.getTypingDisplayText(for: peer), !typingText.isEmpty {
      return .typing(typingText)
    }

    if resolvedChat() != nil {
      return .none
    }

    guard let user = resolvedUserInfo()?.user else { return .none }
    guard !user.isCurrentUser() else { return .none }

    if let action = ComposeActions.shared.getComposeAction(for: peer)?.action, action != .typing {
      return .text(action.toHumanReadable())
    }

    guard let localTime = resolvedLocalTime(for: user) else {
      return .none
    }

    return .text(localTime)
  }

  private func resolvedUserInfo() -> UserInfo? {
    if let userId = peer.asUserId() {
      return ObjectCache.shared.getUser(id: userId) ?? loadedUserInfo
    }

    return loadedUserInfo
  }

  private func resolvedChat() -> Chat? {
    if let chatId = peer.asThreadId() {
      return ObjectCache.shared.getChat(id: chatId) ?? loadedChat
    }

    return loadedChat
  }

  private func resolvedParentThread() -> ParentThread? {
    guard let chat = resolvedChat(), chat.isReplyThread, let parentChatId = chat.parentChatId else { return nil }
    let parent = ObjectCache.shared.getChat(id: parentChatId) ?? loadedParentChat
    let peer = parentPeer(for: parent, parentChatId: parentChatId)
    let title = parent.map(parentTitle) ?? "Thread"
    return ParentThread(peer: peer, title: title)
  }

  private func parentTitle(for chat: Chat) -> String {
    if chat.type == .privateChat {
      if let userInfo = parentUserInfo(for: chat) {
        return userInfo.user.isCurrentUser() ? "Saved Messages" : userInfo.user.displayName
      }
      return "Direct Message"
    }

    return ReplyThreadTitleFallback.title(for: chat, anchorText: nil)
  }

  private func parentPeer(for chat: Chat?, parentChatId: Int64) -> Peer {
    guard chat?.type == .privateChat else {
      return .thread(id: parentChatId)
    }

    if let userId = loadedParentPeerUserId ?? loadedParentUserInfo?.id ?? chat?.peerUserId {
      return .user(id: userId)
    }

    return .thread(id: parentChatId)
  }

  private func parentUserInfo(for chat: Chat) -> UserInfo? {
    if let loadedParentUserInfo {
      return loadedParentUserInfo
    }

    guard let userId = loadedParentPeerUserId ?? chat.peerUserId else { return nil }
    return ObjectCache.shared.getUser(id: userId)
  }

  private func resolvedLocalTime(for user: User? = nil) -> String? {
    let user = user ?? resolvedUserInfo()?.user
    guard let user else { return nil }
    guard let timeZone = user.timeZone, timeZone != TimeZone.current.identifier else { return nil }
    guard let text = TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: timeZone), !text.isEmpty else {
      return nil
    }
    return text
  }

  private func updateParentChatSubscription() {
    guard let parentChatId = resolvedChat()?.parentChatId else {
      parentChatCancellable?.cancel()
      parentChatCancellable = nil
      observedParentChatId = nil
      return
    }

    guard observedParentChatId != parentChatId else { return }
    observedParentChatId = parentChatId

    parentChatCancellable?.cancel()
    parentChatCancellable = ObjectCache.shared.getChatPublisher(id: parentChatId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.parentThread = self?.resolvedParentThread()
      }
  }

  private func updateSpaceSubscription() {
    let spaceId = resolvedSpaceId()
    guard observedSpaceId != spaceId else { return }

    spaceCancellable?.cancel()
    spaceCancellable = nil
    observedSpaceId = spaceId
    loadedSpace = nil

    guard let spaceId else { return }

    spaceCancellable = ValueObservation.tracking { db in
      try Space.fetchOne(db, id: spaceId)
    }
    .start(in: db.reader, scheduling: .immediate, onError: { [weak self] error in
      Log.shared.error("Failed to observe window title space \(spaceId): \(error)")
      self?.observedSpaceId = nil
    }, onChange: { [weak self] space in
      self?.loadedSpace = space
      self?.refreshWindowTitle()
    })
  }

  private func resolvedSpaceId() -> Int64? {
    resolvedChat()?.spaceId ?? contextSpaceId
  }

  private func loadSnapshot() {
    snapshotTask?.cancel()
    snapshotTask = Task { [weak self] in
      guard let self else { return }

      do {
        let peer = self.peer
        let snapshot = try await db.reader.read { db in
          try Self.fetchSnapshot(peer: peer, db: db)
        }
        guard !Task.isCancelled else { return }
        apply(snapshot)
        sync()
      } catch {
        log.error("Failed to load toolbar title snapshot", error: error)
      }
    }
  }

  private func loadInitialSnapshot() {
    guard let snapshot = try? db.reader.read({ db in
      try Self.fetchSnapshot(peer: peer, db: db)
    }) else { return }

    apply(snapshot)
  }

  private func apply(_ snapshot: Snapshot) {
    loadedChat = snapshot.chat
    loadedParentChat = snapshot.parentChat
    loadedParentUserInfo = snapshot.parentUserInfo
    loadedParentPeerUserId = snapshot.parentPeerUserId
    loadedAnchorText = snapshot.anchorText
    loadedUserInfo = snapshot.userInfo
  }

  nonisolated private static func fetchSnapshot(
    peer: Peer,
    db: Database
  ) throws -> Snapshot {
    switch peer {
    case let .thread(chatId):
      let chat = try Chat.fetchOne(db, id: chatId)
      let parentChat: Chat?
      if let parentChatId = chat?.parentChatId {
        parentChat = try Chat.fetchOne(db, id: parentChatId)
      } else {
        parentChat = nil
      }
      let parentDialog = try parentChat.flatMap { parentChat in
        try Dialog
          .filter(Column("chatId") == parentChat.id)
          .fetchOne(db)
      }
      let parentPeerUserId = parentDialog?.peerUserId ?? parentChat?.peerUserId
      let parentUserInfo = try parentPeerUserId.flatMap { userId in
        try User
          .userInfoQuery()
          .filter(Column("id") == userId)
          .fetchOne(db)
      }
      let anchorText: String?
      if let chat {
        anchorText = try ReplyThreadTitleFallback.anchorText(for: chat, db: db)
      } else {
        anchorText = nil
      }
      return Snapshot(
        chat: chat,
        userInfo: nil,
        parentChat: parentChat,
        parentUserInfo: parentUserInfo,
        parentPeerUserId: parentPeerUserId,
        anchorText: anchorText
      )
    case .user:
      let item = try Dialog
        .spaceChatItemQueryForUser()
        .filter(id: Dialog.getDialogId(peerId: peer))
        .fetchOne(db)
      return Snapshot(
        chat: item?.chat,
        userInfo: item?.userInfo,
        parentChat: nil,
        parentUserInfo: nil,
        parentPeerUserId: nil,
        anchorText: nil
      )
    }
  }

  private func refreshRenameEligibility() {
    renameEligibilityTask?.cancel()
    renameEligibilityTask = Task { [weak self] in
      guard let self else { return }
      let canRename = await resolveCanRename()
      guard !Task.isCancelled else { return }
      self.canRename = canRename
    }
  }

  private func resolveCanRename() async -> Bool {
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }

    do {
      return try await db.reader.read { db in
        try ChatRenamePermission.canRename(peer: peer, currentUserId: currentUserId, db: db)
      }
    } catch {
      log.error("Failed to check chat rename eligibility", error: error)
      return false
    }
  }

  private static func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return nil }
    return String(first)
  }
}

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

  let peer: Peer

  var title: String
  var windowTitle: String
  var iconPeer: ChatIcon.PeerType?
  var status: Status = .none
  var canRename = false
  var isEditingTitle = false
  var isSavingTitle = false
  var titleDraft = ""

  @ObservationIgnored private let db: AppDatabase
  @ObservationIgnored private let log = Log.scoped("ChatRouteToolbarTitle")
  @ObservationIgnored private var loadedChat: Chat?
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
    isEditingTitle = true
  }

  func cancelEditingTitle() {
    titleDraft = title
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

    if trimmedTitle == title {
      cancelEditingTitle()
      return
    }

    title = trimmedTitle
    titleDraft = trimmedTitle
    refreshWindowTitle()
    isEditingTitle = false
    isSavingTitle = true

    Task { [weak self] in
      guard let self else { return }
      defer { isSavingTitle = false }

      do {
        _ = try await Api.realtime.send(.updateChatInfo(
          chatID: chatId,
          title: trimmedTitle,
          emoji: nil
        ))
      } catch {
        log.error("Failed to update chat title", error: error)
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
    }
    iconPeer = resolvedIconPeer()
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
      return chat.humanReadableTitle ?? "Untitled"
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

    if let chat = resolvedChat() {
      if chat.isReplyThread, let parentChatId = chat.parentChatId {
        let parentTitle = ObjectCache.shared.getChat(id: parentChatId)?.humanReadableTitle ?? "Thread"
        return .text(parentTitle)
      }

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
        self?.refreshStatus()
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
        loadedChat = snapshot.chat
        loadedUserInfo = snapshot.userInfo
        sync()
      } catch {
        log.error("Failed to load toolbar title snapshot", error: error)
      }
    }
  }

  nonisolated private static func fetchSnapshot(peer: Peer, db: Database) throws -> (chat: Chat?, userInfo: UserInfo?) {
    switch peer {
    case let .thread(chatId):
      return (try Chat.fetchOne(db, id: chatId), nil)
    case .user:
      let item = try Dialog
        .spaceChatItemQueryForUser()
        .filter(id: Dialog.getDialogId(peerId: peer))
        .fetchOne(db)
      return (item?.chat, item?.userInfo)
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
}

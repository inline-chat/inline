import Combine
import Foundation
import GRDB
import InlineCompat
import InlineProtocol
import Logger
import Observation
import RealtimeV2

/// The Threads tab of chat info: subthreads of a thread, or the threads the
/// viewer shares with a person or bot.
///
/// Rows render from the local database first and refresh from the server, so
/// the tab opens with what is cached instead of a spinner.
@MainActor
public final class PeerInfoThreadsModel: CompatObservable {
  public let observationRegistrar = CompatObservationRegistrar()
  public struct Item: Identifiable, Equatable, Sendable {
    public var chat: Chat
    public var dialog: Dialog?
    public var space: Space?
    /// Last message date, else the chat's creation date.
    public var activityDate: Date

    public var id: Int64 { chat.id }
    public var peer: Peer { .thread(id: chat.id) }
    public var unreadCount: Int { max(dialog?.unreadCount ?? 0, 0) }
  }

  public enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(hasMore: Bool)
    case failed
    /// The server is too old to answer; the tab says so instead of retrying.
    case unsupported
  }

  public enum Source: Equatable, Sendable {
    case subthreads(chatId: Int64)
    case common(userId: Int64)
  }

  @Tracked public private(set) var items: [Item] = []
  @Tracked public private(set) var loadState: LoadState = .idle

  public let source: Source

  private let db: AppDatabase
  private let realtime: RealtimeV2
  private var observation: AnyCancellable?
  private var loadTask: Task<Void, Never>?
  /// Common chats come back as an ordered list of IDs; the database holds the rows.
  private var commonChatIds: [Int64] = []
  private var nextCommonOffset: InlineProtocol.ChatListOffset?
  private var nextSubthreadOffset: Int64?
  private let log = Log.scoped("PeerInfoThreads")

  private static let pageSize: Int32 = 30
  /// Common-chat IDs per user for this launch, so reopening a profile is instant.
  private static var commonChatIdsCache: [Int64: [Int64]] = [:]

  public init(source: Source, db: AppDatabase = .shared, realtime: RealtimeV2 = Api.realtime) {
    self.source = source
    self.db = db
    self.realtime = realtime
    if case let .common(userId) = source {
      commonChatIds = Self.commonChatIdsCache[userId] ?? []
    }
    items = (try? db.reader.read { [source, commonChatIds] db in
      try Self.fetchItems(db, source: source, commonChatIds: commonChatIds)
    }) ?? []
  }

  public static func source(for subject: PeerInfoSubject) -> Source? {
    switch (subject.kind, subject.peer) {
    case let (.thread, .thread(id)):
      .subthreads(chatId: id)
    case let (.person, .user(id)), let (.bot, .user(id)):
      .common(userId: id)
    default:
      nil
    }
  }

  /// Starts observing local rows and loads the first page from the server.
  public func start() {
    observe()
    guard loadTask == nil, loadState == .idle || loadState == .failed else { return }
    loadPage(reset: true)
  }

  public func loadMore() {
    guard case .loaded(hasMore: true) = loadState, loadTask == nil else { return }
    loadPage(reset: false)
  }

  public func retry() {
    guard loadTask == nil else { return }
    loadPage(reset: true)
  }

  public func stop() {
    observation?.cancel()
    observation = nil
    loadTask?.cancel()
    loadTask = nil
    if loadState == .loading { loadState = .idle }
  }

  // MARK: Loading

  private func loadPage(reset: Bool) {
    #if DEBUG
    if PeerInfoDebugFixture.isRequested {
      loadFromFixture()
      return
    }
    #endif
    loadState = .loading
    loadTask = Task { [weak self] in
      guard let self else { return }
      defer { self.loadTask = nil }
      do {
        let hasMore = switch source {
        case let .subthreads(chatId): try await loadSubthreads(chatId: chatId, reset: reset)
        case let .common(userId): try await loadCommon(userId: userId, reset: reset)
        }
        guard !Task.isCancelled else { return }
        loadState = .loaded(hasMore: hasMore)
        refreshFromDatabase()
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        if Self.isUnsupported(error) {
          loadState = .unsupported
        } else {
          log.error("Failed to load chat info threads", error: error)
          loadState = .failed
        }
      }
    }
  }

  private func loadSubthreads(chatId: Int64, reset: Bool) async throws -> Bool {
    let offset = reset ? nil : nextSubthreadOffset
    let result = try await realtime.send(.getThreadSubthreads(chatID: chatId, offsetID: offset, limit: Self.pageSize))
    guard case let .getThreadSubthreads(response) = result else { return false }
    nextSubthreadOffset = response.items.last?.id
    return response.items.count >= Int(Self.pageSize)
  }

  private func loadCommon(userId: Int64, reset: Bool) async throws -> Bool {
    let offset = reset ? nil : nextCommonOffset
    let result = try await realtime.send(.getCommonChats(userID: userId, offset: offset, limit: Self.pageSize))
    guard case let .getCommonChats(response) = result else { return false }
    let ids = response.chats.map(\.id)
    commonChatIds = reset ? ids : commonChatIds + ids.filter { !commonChatIds.contains($0) }
    Self.commonChatIdsCache[userId] = commonChatIds
    nextCommonOffset = response.hasNextOffset ? response.nextOffset : nil
    if reset { observe(force: true) }
    return response.hasNextOffset
  }

  #if DEBUG
  /// The harness has no server: shared threads come from local participants.
  private func loadFromFixture() {
    if case let .common(userId) = source {
      let viewer = PeerInfoDebugFixture.me
      commonChatIds = (try? db.reader.read { db in
        let theirs = try ChatParticipant.filter(Column("userId") == userId).fetchAll(db).map(\.chatId)
        let mine = Set(try ChatParticipant.filter(Column("userId") == viewer).fetchAll(db).map(\.chatId))
        let shared = theirs.filter { mine.contains($0) }
        // Like the server: top-level, non-public threads only.
        let threads = try Chat.filter(shared.contains(Chat.Columns.id)).fetchAll(db)
          .filter { $0.parentChatId == nil && $0.isPublic != true && $0.type == .thread }
        return threads.map(\.id)
      }) ?? []
      observe(force: true)
    }
    loadState = .loaded(hasMore: false)
  }
  #endif

  private static func isUnsupported(_ error: Error) -> Bool {
    let text = String(describing: error).lowercased()
    return text.contains("unsupported") || text.contains("unknown method")
  }

  // MARK: Local rows

  private func observe(force: Bool = false) {
    guard observation == nil || force else { return }
    observation?.cancel()
    let source = source
    let ids = commonChatIds
    db.warnIfInMemoryDatabaseForObservation("PeerInfoThreadsModel.items")
    observation = ValueObservation
      .tracking { db in try Self.fetchItems(db, source: source, commonChatIds: ids) }
      .removeDuplicates()
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Chat info threads observation failed", error: error)
          }
        },
        receiveValue: { [weak self] items in
          guard let self, self.items != items else { return }
          self.items = items
        }
      )
  }

  private func refreshFromDatabase() {
    if case .common = source { observe(force: true) }
  }

  nonisolated static func fetchItems(_ db: Database, source: Source, commonChatIds: [Int64]) throws -> [Item] {
    let chats: [Chat]
    switch source {
    case let .subthreads(chatId):
      chats = try Chat.filter(Chat.Columns.parentChatId == chatId).fetchAll(db)
    case .common:
      guard !commonChatIds.isEmpty else { return [] }
      let fetched = try Chat.filter(commonChatIds.contains(Chat.Columns.id)).fetchAll(db)
      let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      chats = commonChatIds.compactMap { byId[$0] }
    }
    guard !chats.isEmpty else { return [] }

    let chatIds = chats.map(\.id)
    let dialogs = try Dialog.filter(chatIds.contains(Dialog.Columns.chatId)).fetchAll(db)
    let dialogByChat = Dictionary(dialogs.compactMap { dialog in dialog.chatId.map { ($0, dialog) } }, uniquingKeysWith: { first, _ in first })

    let spaceIds = Set(chats.compactMap(\.spaceId))
    let spaces = spaceIds.isEmpty ? [] : try Space.filter(keys: Array(spaceIds)).fetchAll(db)
    let spaceById = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    var lastDates: [Int64: Date] = [:]
    for chat in chats {
      guard let lastMsgId = chat.lastMsgId else { continue }
      if let message = try Message
        .filter(Message.Columns.chatId == chat.id)
        .filter(Message.Columns.messageId == lastMsgId)
        .fetchOne(db)
      {
        lastDates[chat.id] = message.date
      }
    }

    let items = chats.map { chat in
      Item(
        chat: chat,
        dialog: dialogByChat[chat.id],
        space: chat.spaceId.flatMap { spaceById[$0] },
        activityDate: lastDates[chat.id] ?? chat.date
      )
    }

    switch source {
    case .subthreads:
      return items.sorted { lhs, rhs in
        lhs.activityDate == rhs.activityDate ? lhs.chat.id > rhs.chat.id : lhs.activityDate > rhs.activityDate
      }
    case .common:
      // The server already ordered these by activity.
      return items
    }
  }
}

@available(iOS 17.0, macOS 14.0, *)
extension PeerInfoThreadsModel: Observable {}

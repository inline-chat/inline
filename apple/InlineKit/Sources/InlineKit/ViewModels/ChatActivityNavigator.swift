import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger

/// Drives the in-chat floating buttons: how many mentions (replies included) and reactions are
/// unseen, which one to jump to next, and marking each read once it has stayed on screen briefly.
/// It also carries the dialog's unread count and read marker for the scroll-to-bottom count
/// (see `ChatUnreadBadgeCount`).
///
/// The message list reports what is visible through `noteVisible(messageIds:)`, only while the
/// chat is actually being looked at (app active, window key or scene foreground).
@MainActor
public final class ChatActivityNavigator {
  public struct State: Equatable, Sendable {
    /// Unseen mentions and replies, as shown on the @ button.
    public var mentionsCount: Int
    public var reactionsCount: Int
    /// Unread messages, as the server counts them after `readInboxMaxId`.
    public var unreadCount: Int = 0
    public var readInboxMaxId: Int64 = 0
    public var unreadMark = false

    public static let empty = State(mentionsCount: 0, reactionsCount: 0)

    /// Whether the @ and ♥ buttons, which take stack slots, changed.
    public func hasSameActivity(as other: State) -> Bool {
      mentionsCount == other.mentionsCount && reactionsCount == other.reactionsCount
    }
  }

  public let peerId: Peer
  public let chatId: Int64

  /// What the navigator asks the server to do. Injected so the behavior can be exercised offline.
  public enum Request: Equatable, Sendable {
    case refill(ChatActivityItem.Kind)
    case read(messageIds: [Int64])
    case readAll(ChatActivityItem.Kind, maxId: Int64?)
  }

  public typealias Sender = @Sendable (Request, Peer, Int64) async throws -> Void

  private let database: AppDatabase
  private let send: Sender

  public static let liveSender: Sender = { request, peerId, chatId in
    switch request {
      case let .refill(kind):
        _ = try await Api.realtime.send(.getUnreadActivity(peerId: peerId, chatId: chatId, kind: kind))
      case let .read(messageIds):
        _ = try await Api.realtime.send(.readActivity(peerId: peerId, chatId: chatId, messageIds: messageIds))
      case let .readAll(kind, maxId):
        _ = try await Api.realtime.send(.readAllActivity(peerId: peerId, chatId: chatId, kinds: [kind], maxId: maxId))
    }
  }

  /// Called on the main actor whenever the counts change, including once on start.
  public var onChange: ((State) -> Void)?
  public private(set) var state: State = .empty

  /// How long an item must stay on screen before it counts as seen.
  static let visibleDwell: Duration = .milliseconds(200)

  private var cancellable: AnyCancellable?
  /// Unread rows known locally, mentions and reactions together (a message is only ever one).
  private var unreadIds: Set<Int64> = []
  private var visibleIds: Set<Int64> = []
  private var dwellTask: Task<Void, Never>?
  private var refilledKinds: Set<ChatActivityItem.Kind> = []
  private let log = Log.scoped("ChatActivityNavigator")

  public init(peerId: Peer, chatId: Int64, database: AppDatabase = .shared, send: @escaping Sender = liveSender) {
    self.peerId = peerId
    self.chatId = chatId
    self.database = database
    self.send = send
  }

  public func start() {
    guard cancellable == nil else { return }
    let peerId = peerId
    let chatId = chatId
    let observation = ValueObservation
      .tracking { db in try Self.fetchSnapshot(db, peerId: peerId, chatId: chatId) }
      .removeDuplicates()
    cancellable = observation
      .publisher(in: database.reader, scheduling: .immediate)
      .sink(
        receiveCompletion: { [log] completion in
          if case let .failure(error) = completion {
            log.error("Failed to observe chat activity", error: error)
          }
        },
        receiveValue: { [weak self] snapshot in
          self?.receive(snapshot)
        }
      )
  }

  private struct Snapshot: Equatable {
    var state: State
    var items: [ChatActivityItem]
  }

  private nonisolated static func fetchSnapshot(_ db: Database, peerId: Peer, chatId: Int64) throws -> Snapshot {
    let dialog = try Dialog.get(peerId: peerId).fetchOne(db)
    let state = State(
      mentionsCount: max(0, dialog?.unreadMentionsCount ?? 0),
      reactionsCount: max(0, dialog?.unreadReactionsCount ?? 0),
      unreadCount: max(0, dialog?.unreadCount ?? 0),
      readInboxMaxId: max(0, dialog?.readInboxMaxId ?? 0),
      unreadMark: dialog?.unreadMark == true
    )
    return Snapshot(state: state, items: try ChatActivityItem.unread(chatId: chatId).fetchAll(db))
  }

  public func stop() {
    cancellable?.cancel()
    cancellable = nil
    dwellTask?.cancel()
    dwellTask = nil
  }

  private func receive(_ snapshot: Snapshot) {
    let state = snapshot.state
    unreadIds = Set(snapshot.items.map(\.messageId))
    let changed = state != self.state
    self.state = state
    if changed { onChange?(state) }
    // Rows may be missing locally after a cold start or a long offline period. Once per kind
    // per chat open; taps refill again when nothing is known locally.
    var local = ActivityCounts()
    for item in snapshot.items { local[item.kind] += 1 }
    let expected = ActivityCounts(mentions: state.mentionsCount, reactions: state.reactionsCount)
    for kind in ChatActivityItem.Kind.allCases where expected[kind] > local[kind] && !refilledKinds.contains(kind) {
      refilledKinds.insert(kind)
      perform(.refill(kind))
    }
    scheduleDwellIfNeeded()
  }

  private func perform(_ request: Request) {
    let peerId = peerId
    let chatId = chatId
    let send = send
    Task(priority: .userInitiated) { [log] in
      do {
        try await send(request, peerId, chatId)
      } catch {
        log.error("Activity request failed", error: error)
      }
    }
  }

  // MARK: - Navigation

  /// The oldest unseen mention or reply, refilling from the server when none is known locally.
  public func nextMessageId() async -> Int64? {
    await next(.mention, expected: state.mentionsCount)
  }

  /// The oldest message of yours with an unseen reaction.
  public func nextReactionMessageId() async -> Int64? {
    await next(.reaction, expected: state.reactionsCount)
  }

  private func next(_ kind: ChatActivityItem.Kind, expected: Int) async -> Int64? {
    if let id = try? await oldestLocal(kind) { return id }
    guard expected > 0 else { return nil }
    do {
      try await send(.refill(kind), peerId, chatId)
    } catch {
      log.error("Failed to load unread activity", error: error)
      return nil
    }
    return try? await oldestLocal(kind)
  }

  private func oldestLocal(_ kind: ChatActivityItem.Kind) async throws -> Int64? {
    let chatId = chatId
    return try await database.reader.read { db in
      try ChatActivityItem.oldestUnread(db, chatId: chatId, kind: kind)?.messageId
    }
  }

  /// The target could not be shown (deleted or no longer accessible); drop it so the next tap moves on.
  public func discard(messageId: Int64) {
    let chatId = chatId
    let database = database
    Task {
      try? await database.dbWriter.write { db in
        _ = try ChatActivityItem
          .filter(ChatActivityItem.Columns.chatId == chatId)
          .filter(ChatActivityItem.Columns.messageId == messageId)
          .deleteAll(db)
      }
    }
  }

  // MARK: - Reading

  /// Reports every message currently on screen, yours included (reactions are on your messages).
  /// Unseen ones that stay visible for `visibleDwell` are marked read.
  public func noteVisible(messageIds: some Sequence<Int64>) {
    visibleIds = Set(messageIds)
    scheduleDwellIfNeeded()
  }

  /// The chat stopped being looked at (scrolled away, window resigned, app backgrounded).
  public func clearVisible() {
    visibleIds = []
    dwellTask?.cancel()
    dwellTask = nil
  }

  private func scheduleDwellIfNeeded() {
    guard dwellTask == nil else { return }
    guard !visibleIds.isDisjoint(with: unreadIds) else { return }
    dwellTask = Task { [weak self] in
      try? await Task.sleep(for: Self.visibleDwell)
      guard let self, !Task.isCancelled else { return }
      self.dwellTask = nil
      let seen = self.visibleIds.intersection(self.unreadIds)
      guard !seen.isEmpty else { return }
      // Hide them now so a second dwell does not resend while the request is in flight.
      self.unreadIds.subtract(seen)
      self.perform(.read(messageIds: seen.sorted()))
    }
  }

  public func markAllMentionsRead() {
    markAllRead(.mention)
  }

  public func markAllReactionsRead() {
    markAllRead(.reaction)
  }

  private func markAllRead(_ kind: ChatActivityItem.Kind) {
    let chatId = chatId
    // Bounded by what this device has seen, so a mention arriving mid-request stays unread.
    let maxId = try? database.reader.read { db in try ChatActivityItem.markAllBound(db, chatId: chatId) }
    perform(.readAll(kind, maxId: maxId ?? nil))
  }
}

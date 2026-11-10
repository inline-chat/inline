import Auth
import Foundation
import GRDB
import Logger

/// The place a user left a chat at: the top of `messageId`'s row sits `offset` points below the
/// top inset. The unread line is the same kind of place, at its row with offset 0.
public struct ChatReadingPlace: Sendable, Equatable, Codable {
  public var messageId: Int64
  public var offset: CGFloat

  public init(messageId: Int64, offset: CGFloat) {
    self.messageId = messageId
    self.offset = offset
  }
}

/// Where a chat opens, decided once before its first frame. Explicit targets (links, search,
/// a notification about an existing message) are resolved by their callers.
public enum ChatOpenAnchor: Sendable, Equatable {
  /// The saved reading place; its row is in the window.
  case saved(ChatReadingPlace)
  /// The unread line, above the first unread message after this last read id.
  case unread(boundary: Int64)
  /// The newest messages.
  case latest
}

/// Reading places kept while the app runs, per account and chat. The lists save a place when
/// the newest message is off screen and clear it at the bottom, on send, on return to latest and
/// on a notification open.
@MainActor
public final class ChatReadingPlaceStore {
  public static let shared = ChatReadingPlaceStore(storage: DatabaseChatReadingPlaceStorage(database: .shared))

  private let accountId: @MainActor () -> Int64?
  private let storage: any ChatReadingPlaceStorage

  /// `accountId` is the signed-in user. Places are keyed by it, so one account never reads
  /// another's, and nothing is kept or returned while signed out.
  init(
    accountId: @escaping @MainActor () -> Int64? = { Auth.shared.getCurrentUserId() },
    storage: any ChatReadingPlaceStorage = MemoryChatReadingPlaceStorage()
  ) {
    self.accountId = accountId
    self.storage = storage
  }

  public func place(for peer: Peer) -> ChatReadingPlace? {
    guard let account = accountId() else { return nil }
    return storage.place(account: account, peer: peer)
  }

  public func save(_ place: ChatReadingPlace, for peer: Peer) {
    guard let account = accountId() else { return }
    storage.save(place, account: account, peer: peer)
  }

  public func clear(for peer: Peer) {
    guard let account = accountId() else { return }
    storage.clear(account: account, peer: peer)
  }
}

/// Where reading places are kept: the local table in the app, memory in tests.
@MainActor
protocol ChatReadingPlaceStorage: AnyObject {
  func place(account: Int64, peer: Peer) -> ChatReadingPlace?
  func save(_ place: ChatReadingPlace, account: Int64, peer: Peer)
  func clear(account: Int64, peer: Peer)
}

@MainActor
final class MemoryChatReadingPlaceStorage: ChatReadingPlaceStorage {
  private struct Key: Hashable {
    let account: Int64
    let peer: Peer
  }

  private var places: [Key: ChatReadingPlace] = [:]

  func place(account: Int64, peer: Peer) -> ChatReadingPlace? {
    places[Key(account: account, peer: peer)]
  }

  func save(_ place: ChatReadingPlace, account: Int64, peer: Peer) {
    places[Key(account: account, peer: peer)] = place
  }

  func clear(account: Int64, peer: Peer) {
    places[Key(account: account, peer: peer)] = nil
  }
}

/// One row of the `chatReadingPlace` table.
struct ChatReadingPlaceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
  static let databaseTableName = "chatReadingPlace"

  var userId: Int64
  var dialogId: Int64
  var messageId: Int64
  var offset: Double
  var updatedAt: Date
}

/// Reading places kept in the local database, so they survive a restart. Reads are answered
/// from memory; the account's rows are read once, on the first read, because a chat restored at
/// launch needs its place before its first frame. Writes go to the database in the order made.
@MainActor
final class DatabaseChatReadingPlaceStorage: ChatReadingPlaceStorage {
  private let database: AppDatabase
  private var places: [Int64: ChatReadingPlace] = [:]
  private var loadedAccount: Int64?

  init(database: AppDatabase) {
    self.database = database
  }

  func place(account: Int64, peer: Peer) -> ChatReadingPlace? {
    loadIfNeeded(account: account)
    return places[Dialog.getDialogId(peerId: peer)]
  }

  func save(_ place: ChatReadingPlace, account: Int64, peer: Peer) {
    loadIfNeeded(account: account)
    let dialogId = Dialog.getDialogId(peerId: peer)
    guard places[dialogId] != place else { return }
    places[dialogId] = place
    let record = ChatReadingPlaceRecord(
      userId: account, dialogId: dialogId, messageId: place.messageId, offset: Double(place.offset), updatedAt: Date()
    )
    write { db in try record.save(db) }
  }

  func clear(account: Int64, peer: Peer) {
    loadIfNeeded(account: account)
    let dialogId = Dialog.getDialogId(peerId: peer)
    guard places.removeValue(forKey: dialogId) != nil else { return }
    write { db in
      _ = try ChatReadingPlaceRecord
        .filter(Column("userId") == account && Column("dialogId") == dialogId)
        .deleteAll(db)
    }
  }

  private func loadIfNeeded(account: Int64) {
    guard loadedAccount != account else { return }
    loadedAccount = account
    places = [:]
    do {
      let records = try database.reader.read { db in
        try ChatReadingPlaceRecord.filter(Column("userId") == account).fetchAll(db)
      }
      for record in records {
        places[record.dialogId] = ChatReadingPlace(messageId: record.messageId, offset: CGFloat(record.offset))
      }
    } catch {
      Log.shared.error("Failed to read chat reading places", error: error)
    }
  }

  /// The writer runs these one at a time in the order they were submitted, so a save followed
  /// by a clear cannot land the other way round.
  private func write(_ updates: @escaping @Sendable (Database) throws -> Void) {
    database.dbWriter.asyncWrite(updates) { _, result in
      if case let .failure(error) = result {
        Log.shared.error("Failed to write chat reading place", error: error)
      }
    }
  }
}

/// Choosing where a chat opens and the window it opens on, from the local cache only:
/// the saved reading place, else the unread line, else the latest messages.
public enum ChatOpening {
  public struct Resolution: Sendable {
    public let anchor: ChatOpenAnchor
    /// The window to open on, oldest first.
    public let messages: [FullMessage]
    /// The last read id the unread line is drawn after, frozen for the visit, whichever anchor
    /// won. Nil when nothing is unread.
    public let unreadBoundary: Int64?
    /// Set when the cache cannot show the unread line, so the chat opens on the latest messages
    /// and the caller may fetch around the line. Nil otherwise.
    public let uncachedUnreadBoundary: Int64?
    /// The saved place could not be shown from the cache and should be cleared by the caller.
    public let droppedSavedPlace: Bool
  }

  /// One database snapshot decides the anchor and its window. `latest` is the latest page the
  /// caller already read (oldest first); it is the window whenever it can show the anchor.
  public nonisolated static func resolve(
    _ db: Database,
    peer: Peer,
    chatId: Int64? = nil,
    saved: ChatReadingPlace?,
    unreadCount: Int?,
    readInboxMaxId: Int64?,
    latest: [FullMessage]
  ) throws -> Resolution {
    let boundary = ChatUnreadOpening.boundary(unreadCount: unreadCount, readInboxMaxId: readInboxMaxId)

    if let saved, let window = try savedPlaceWindow(db, peer: peer, chatId: chatId, place: saved, latest: latest) {
      return Resolution(
        anchor: .saved(saved), messages: window, unreadBoundary: boundary,
        uncachedUnreadBoundary: nil, droppedSavedPlace: false
      )
    }
    // A saved place is never fetched: without its row in a continuous cached window it is dropped.
    let dropped = saved != nil

    guard let boundary else {
      return Resolution(
        anchor: .latest, messages: latest, unreadBoundary: nil,
        uncachedUnreadBoundary: nil, droppedSavedPlace: dropped
      )
    }
    if let window = try ChatUnreadOpening.localOpeningWindow(
      db, peer: peer, chatId: chatId, boundary: boundary, latest: latest
    ) {
      return Resolution(
        anchor: .unread(boundary: boundary), messages: window, unreadBoundary: boundary,
        uncachedUnreadBoundary: nil, droppedSavedPlace: dropped
      )
    }
    return Resolution(
      anchor: .latest, messages: latest, unreadBoundary: boundary,
      uncachedUnreadBoundary: boundary, droppedSavedPlace: dropped
    )
  }

  /// A cached window holding the saved place's row that coverage proves continuous, or nil.
  /// The latest page comes first, so a place near the bottom stays attached to live messages.
  /// A deleted row drops the place: there is nothing to put at its offset.
  nonisolated static func savedPlaceWindow(
    _ db: Database,
    peer: Peer,
    chatId: Int64?,
    place: ChatReadingPlace,
    latest: [FullMessage]
  ) throws -> [FullMessage]? {
    let id = place.messageId
    guard id > 0 else { return nil }
    if latest.contains(where: { $0.message.messageId == id }), try isContinuous(latest, db: db, peer: peer) {
      return latest
    }
    guard let around = try ChatUnreadOpening.certifiedWindow(db, peer: peer, chatId: chatId, boundary: id),
          around.contains(where: { $0.message.messageId == id })
    else { return nil }
    return around
  }

  /// Whether the view model keeps every row of a window: no unknown history between them.
  /// The same check `ChatUnreadOpening.certifiedWindow` applies to the window it reads.
  nonisolated static func isContinuous(_ window: [FullMessage], db: Database, peer: Peer) throws -> Bool {
    let metadata = try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: peer, messages: window)
    return metadata.historyCoverage.contiguousWindow(from: window).count == window.count
  }
}

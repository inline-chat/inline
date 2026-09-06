import Combine
import Foundation
import GRDB
import Logger

/// An in-memory projection of committed dialog preferences. Reads from message
/// rendering never open the database. Each AppDatabase owns its projection.
public final class DialogTranslationPreferences: @unchecked Sendable {
  public let changes = PassthroughSubject<(Peer, Bool), Never>()
  public let notices = PassthroughSubject<(peer: Peer, message: String, isError: Bool), Never>()
  private let lock = NSLock()
  private var values: [Int64: Bool] = [:]
  private var peers: [Int64: Peer] = [:]
  private var pending: [Int64: (id: UUID, enabled: Bool)] = [:]
  private var observer: Observer?

  public init() {}

  public func isEnabled(for peer: Peer) -> Bool {
    let id = Dialog.getDialogId(peerId: peer)
    return lock.withLock { pending[id]?.enabled ?? values[id] ?? false }
  }

  public func begin(_ enabled: Bool, for peer: Peer, intent: UUID) {
    let id = Dialog.getDialogId(peerId: peer)
    let accepted = lock.withLock {
      // Only overlay a materialized dialog. Deleting that row (including
      // logout) then also clears every pending account-owned choice.
      guard values[id] != nil, peers[id] == peer else { return false }
      pending[id] = (intent, enabled)
      return true
    }
    if accepted { changes.send((peer, enabled)) }
  }

  func isCurrentIntent(_ intent: UUID, for peer: Peer) -> Bool {
    lock.withLock { pending[Dialog.getDialogId(peerId: peer)]?.id == intent }
  }

  @discardableResult
  public func finish(for peer: Peer, intent: UUID) -> Bool {
    let id = Dialog.getDialogId(peerId: peer)
    let enabled: Bool? = lock.withLock {
      guard pending[id]?.id == intent else { return nil }
      pending[id] = nil
      return values[id] ?? false
    }
    if let enabled { changes.send((peer, enabled)) }
    return enabled != nil
  }

  func observe(_ writer: any DatabaseWriter) throws {
    // Replacing the observer releases the old database registration.
    observer = nil
    var initialized = false
    defer {
      if !initialized {
        let previousPeers = lock.withLock {
          let previous = Array(peers.values)
          values.removeAll()
          peers.removeAll()
          pending.removeAll()
          return previous
        }
        for peer in previousPeers {
          changes.send((peer, false))
        }
      }
    }
    let next = Observer(owner: self)
    try writer.writeWithoutTransaction { db in
      let rows = try Row.fetchAll(db, sql: "SELECT id, peerUserId, peerThreadId, translationEnabled FROM dialog")
      let snapshot = Dictionary(uniqueKeysWithValues: rows.map { row in
        (row["id"] as Int64, (row["translationEnabled"] as Bool?) ?? false)
      })
      let peerSnapshot = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (Int64, Peer)? in
        guard let peer = Self.peer(from: row) else { return nil }
        return (row["id"] as Int64, peer)
      })
      let changed = self.lock.withLock {
        let ids = Set(self.values.keys).union(snapshot.keys).union(self.pending.keys)
        self.peers.merge(peerSnapshot) { _, new in new }
        self.values = snapshot
        self.pending.removeAll()
        return ids
      }
      for id in changed {
        self.publish(id: id)
      }
      self.lock.withLock { self.peers = peerSnapshot }
      db.add(transactionObserver: next, extent: .observerLifetime)
    }
    observer = next
    initialized = true
  }

  private func refresh(_ ids: Set<Int64>, in db: Database) throws {
    // Refresh only changed rows, including deletion; avoid rescanning every chat
    // when the message/unread path saves a single dialog.
    for id in ids {
      let row = try Row.fetchOne(
        db,
        sql: "SELECT peerUserId, peerThreadId, translationEnabled FROM dialog WHERE id = ?",
        arguments: [id]
      )
      let value = (row?["translationEnabled"] as Bool?) ?? false
      let changed = lock.withLock {
        if let row { peers[id] = Self.peer(from: row) }
        let previous = pending[id]?.enabled ?? values[id] ?? false
        values[id] = row == nil ? nil : value
        if row == nil { pending[id] = nil }
        return previous != (pending[id]?.enabled ?? value)
      }
      if changed { publish(id: id) }
      if row == nil { lock.withLock { peers[id] = nil } }
    }
  }

  private func publish(id: Int64) {
    guard let peer = lock.withLock({ peers[id] }) else { return }
    changes.send((peer, isEnabled(for: peer)))
  }

  private static func peer(from row: Row) -> Peer? {
    if let userID = row["peerUserId"] as Int64? { return .user(id: userID) }
    if let threadID = row["peerThreadId"] as Int64? { return .thread(id: threadID) }
    return nil
  }

  private final class Observer: TransactionObserver {
    weak var owner: DialogTranslationPreferences?
    private var changedIDs = Set<Int64>()

    init(owner: DialogTranslationPreferences) { self.owner = owner }

    func observes(eventsOfKind kind: DatabaseEventKind) -> Bool {
      switch kind {
        case let .insert(tableName), let .delete(tableName):
          tableName == "dialog"
        case let .update(tableName, columnNames):
          tableName == "dialog" && !columnNames.isDisjoint(with: ["translationEnabled", "id"])
      }
    }

    func databaseDidChange(with event: DatabaseEvent) { changedIDs.insert(event.rowID) }
    func databaseWillCommit() throws {}
    func databaseDidRollback(_ db: Database) { changedIDs.removeAll() }

    func databaseDidCommit(_ db: Database) {
      let ids = changedIDs
      changedIDs.removeAll()
      do {
        try owner?.refresh(ids, in: db)
      } catch {
        Log.shared.error("Failed to refresh translation preferences", error: error)
      }
    }
  }
}

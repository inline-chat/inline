import Foundation
import InlineProtocol

public struct RichMessageDraftMessageKey: Hashable, Sendable {
  public let peer: Peer
  public let messageId: Int64

  public init(peer: Peer, messageId: Int64) {
    self.peer = peer
    self.messageId = messageId
  }
}

public struct RichMessageDraftSnapshot: Sendable {
  public let draftId: String
  public let key: RichMessageDraftMessageKey
  public let senderUserId: Int64
  public let richText: RichMessage
  public let expiresAt: Date
}

public struct RichMessageDraftChange: Sendable {
  public let key: RichMessageDraftMessageKey
  public let snapshot: RichMessageDraftSnapshot?
}

public final class RichMessageDraftStore: @unchecked Sendable {
  public static let shared = RichMessageDraftStore()

  private static let maxDraftIDLength = 256

  private struct Entry {
    var draftId: String
    var key: RichMessageDraftMessageKey
    var senderUserId: Int64
    var richText: RichMessage
    var expiresAt: Date
    var sequence: Int64

    var snapshot: RichMessageDraftSnapshot {
      RichMessageDraftSnapshot(
        draftId: draftId,
        key: key,
        senderUserId: senderUserId,
        richText: richText,
        expiresAt: expiresAt
      )
    }
  }

  private let lock = NSLock()
  private var sequence: Int64 = 0
  private var entriesByDraftId: [String: Entry] = [:]
  private var draftIdsByMessage: [RichMessageDraftMessageKey: Set<String>] = [:]

  private init() {}

  public func apply(_ update: UpdateRichMessageDraft, now: Date = Date()) -> [RichMessageDraftChange] {
    guard update.hasPeerID else { return [] }
    let draftID = update.draftID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !draftID.isEmpty, draftID.utf16.count <= Self.maxDraftIDLength else { return [] }

    let peer = update.peerID.toPeer()
    lock.lock()
    defer { lock.unlock() }

    let oldEntry = entriesByDraftId[draftID]
    let previousMessageId = oldEntry?.key.peer == peer ? oldEntry?.key.messageId : nil
    let messageId = update.hasMessageID ? update.messageID : previousMessageId
    guard let messageId else {
      return []
    }

    let key = RichMessageDraftMessageKey(peer: peer, messageId: messageId)
    let affectedKeys = Set([oldEntry?.key, key].compactMap(\.self))

    guard update.clear == false,
          update.hasRichText,
          update.expiresAt > Int64(now.timeIntervalSince1970)
    else {
      return removeDraftLocked(id: draftID, affectedKeys: affectedKeys, now: now)
    }

    sequence += 1

    if let oldKey = oldEntry?.key, oldKey != key {
      draftIdsByMessage[oldKey]?.remove(draftID)
      if draftIdsByMessage[oldKey]?.isEmpty == true {
        draftIdsByMessage.removeValue(forKey: oldKey)
      }
    }

    let entry = Entry(
      draftId: draftID,
      key: key,
      senderUserId: update.senderUserID,
      richText: update.richText,
      expiresAt: Date(timeIntervalSince1970: TimeInterval(update.expiresAt)),
      sequence: sequence
    )
    entriesByDraftId[draftID] = entry
    draftIdsByMessage[key, default: []].insert(draftID)

    return changesLocked(for: affectedKeys, now: now)
  }

  public func snapshot(for peer: Peer, messageId: Int64, now: Date = Date()) -> RichMessageDraftSnapshot? {
    lock.lock()
    let snapshot = latestSnapshotLocked(
      for: RichMessageDraftMessageKey(peer: peer, messageId: messageId),
      now: now
    )
    lock.unlock()
    return snapshot
  }

  public func richText(for peer: Peer, messageId: Int64, now: Date = Date()) -> RichMessage? {
    snapshot(for: peer, messageId: messageId, now: now)?.richText
  }

  public func removeExpired(now: Date = Date()) -> [RichMessageDraftChange] {
    lock.lock()
    let expired = entriesByDraftId.values.filter { $0.expiresAt <= now }
    let keys = Set(expired.map(\.key))

    for entry in expired {
      entriesByDraftId.removeValue(forKey: entry.draftId)
      draftIdsByMessage[entry.key]?.remove(entry.draftId)
      if draftIdsByMessage[entry.key]?.isEmpty == true {
        draftIdsByMessage.removeValue(forKey: entry.key)
      }
    }

    let changes = changesLocked(for: keys, now: now)
    lock.unlock()
    return changes
  }

  public func nextExpiryDate(now: Date = Date()) -> Date? {
    lock.lock()
    let next = entriesByDraftId.values
      .map(\.expiresAt)
      .filter { $0 > now }
      .min()
    lock.unlock()
    return next
  }

  func removeAllForTesting() {
    lock.lock()
    sequence = 0
    entriesByDraftId.removeAll()
    draftIdsByMessage.removeAll()
    lock.unlock()
  }

  private func removeDraftLocked(
    id draftId: String,
    affectedKeys initialKeys: Set<RichMessageDraftMessageKey> = [],
    now: Date = Date()
  ) -> [RichMessageDraftChange] {
    var affectedKeys = initialKeys

    if let entry = entriesByDraftId.removeValue(forKey: draftId) {
      affectedKeys.insert(entry.key)
      draftIdsByMessage[entry.key]?.remove(draftId)
      if draftIdsByMessage[entry.key]?.isEmpty == true {
        draftIdsByMessage.removeValue(forKey: entry.key)
      }
    }

    return changesLocked(for: affectedKeys, now: now)
  }

  private func changesLocked(
    for keys: Set<RichMessageDraftMessageKey>,
    now: Date = Date()
  ) -> [RichMessageDraftChange] {
    keys.sorted { lhs, rhs in
      if lhs.peer.toString() == rhs.peer.toString() {
        return lhs.messageId < rhs.messageId
      }
      return lhs.peer.toString() < rhs.peer.toString()
    }.map { key in
      RichMessageDraftChange(key: key, snapshot: latestSnapshotLocked(for: key, now: now))
    }
  }

  private func latestSnapshotLocked(
    for key: RichMessageDraftMessageKey,
    now: Date = Date()
  ) -> RichMessageDraftSnapshot? {
    draftIdsByMessage[key]?
      .compactMap { entriesByDraftId[$0] }
      .filter { $0.expiresAt > now }
      .max { lhs, rhs in lhs.sequence < rhs.sequence }?
      .snapshot
  }
}

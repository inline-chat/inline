import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

/// Randomized lab for the client's activity ledger. A fake server owns the truth; one device
/// reads rows optimistically while new mentions, reactions, reads from another device, failed
/// requests, dialog snapshots, refills and stale history pages interleave with in-order delivery
/// of user-bucket updates. Once everything is delivered and the device has read whatever stale
/// rows history left behind, it must show exactly the server's counts and unread rows.
@Suite("Activity items convergence")
struct ActivityItemConvergenceTests {
  private let chatId: Int64 = 77

  private struct Key: Hashable, Comparable {
    let messageId: Int64
    let kind: ChatActivityItem.Kind
    static func < (lhs: Key, rhs: Key) -> Bool {
      (lhs.messageId, lhs.kind.rawValue) < (rhs.messageId, rhs.kind.rawValue)
    }
  }

  /// SplitMix64 so failures reproduce from the seed.
  private struct Rng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }

    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
  }

  private final class FakeServer {
    var unread: Set<Key> = []
    var nextMessageId: Int64 = 1

    func count(_ kind: ChatActivityItem.Kind) -> Int { unread.filter { $0.kind == kind }.count }

    func update(peer: InlineProtocol.Peer, added: [Key] = [], cleared: [Int64] = []) -> InlineProtocol.UpdateUnreadActivity {
      .with {
        $0.peerID = peer
        $0.unreadMentionsCount = Int32(count(.mention))
        $0.unreadReactionsCount = Int32(count(.reaction))
        $0.unreadMentionIds = added.filter { $0.kind == .mention }.map(\.messageId)
        $0.unreadReactionIds = added.filter { $0.kind == .reaction }.map(\.messageId)
        $0.clearedMessageIds = cleared
      }
    }

    /// Reads by message ID and echoes every requested ID, changed or not.
    func read(peer: InlineProtocol.Peer, messageIds: [Int64]) -> InlineProtocol.UpdateUnreadActivity {
      let ids = Set(messageIds)
      unread = unread.filter { !ids.contains($0.messageId) }
      return update(peer: peer, cleared: messageIds.sorted())
    }
  }

  @Test("Device converges to the server under random interleavings", arguments: Array(UInt64(1) ... 40))
  func converges(seed: UInt64) throws {
    var rng = Rng(state: seed)
    let server = FakeServer()
    let peer = InlineProtocol.Peer.with { $0.chat = .with { $0.chatID = chatId } }
    let database = AppDatabase.empty()
    // Each update carries the server's unread set at the moment it was produced.
    var deliveries: [(update: InlineProtocol.UpdateUnreadActivity, snapshot: Set<Key>)] = []
    // The server state behind the last update the device applied.
    var lastSnapshot: Set<Key> = []
    // A dialog snapshot can run ahead of queued stream updates (Telegram has the same window).
    // Until those older updates land, a local row the snapshot already excludes can still be
    // read here and dip the count; the strict check resumes once the stream catches up.
    var updatesBehindSnapshot = 0
    var requests: [(messageIds: [Int64], items: [ChatActivityItem])] = []
    // Server states a history page may have been encoded from.
    var pastStates: [Set<Key>] = [[]]

    func dialog(_ db: Database) throws -> InlineKit.Dialog {
      try #require(try InlineKit.Dialog.fetchOne(db, id: InlineKit.Dialog.getDialogId(peerThreadId: chatId)))
    }

    func saveSnapshot(_ db: Database) throws {
      try InlineProtocol.Dialog.with {
        $0.peer = peer
        $0.chatID = chatId
        $0.unreadMentionsCount = Int32(server.count(.mention))
        $0.unreadReactionsCount = Int32(server.count(.reaction))
      }.saveFull(db)
    }

    try database.dbWriter.write { db in
      try Chat(id: chatId, date: .init(timeIntervalSince1970: 1), type: .thread, title: "Lab", spaceId: nil).insert(db)
      try saveSnapshot(db)
    }

    // Recent steps, printed with any failure.
    var trace: [String] = []
    for _ in 0 ..< 120 {
      let action = rng.int(10)
      trace = Array((trace + [["add", "add", "read", "otherRead", "serve", "deliver", "deliver", "snapshot", "refill", "history"][action]]).suffix(10))
      switch action {
        case 0, 1:
          // Someone mentions, replies or reacts.
          let key = Key(messageId: server.nextMessageId, kind: rng.int(2) == 0 ? .mention : .reaction)
          server.nextMessageId += 1
          server.unread.insert(key)
          deliveries.append((server.update(peer: peer, added: [key]), server.unread))

        case 2:
          // The device reads a few rows it knows about on screen.
          let local = try database.dbWriter.read { db in try ChatActivityItem.unread(chatId: chatId).fetchAll(db) }
          guard !local.isEmpty else { continue }
          let picked = Array(local.shuffled(using: &rng).prefix(1 + rng.int(3))).map(\.messageId)
          let marked = try database.dbWriter.write { db in
            try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: picked)
          }
          requests.append((picked, marked))

        case 3:
          // Another device reads something.
          guard let key = server.unread.sorted().randomElement(using: &rng) else { continue }
          deliveries.append((server.read(peer: peer, messageIds: [key.messageId]), server.unread))

        case 4:
          // The server handles the oldest read request, or it fails.
          guard !requests.isEmpty else { continue }
          let request = requests.removeFirst()
          if rng.int(5) == 0 {
            try database.dbWriter.write { db in try ChatActivityItem.rollbackPendingRead(db, items: request.items) }
          } else {
            // Every change reaches every device, the reader included, through the ordered
            // user stream. The RPC result carries nothing.
            deliveries.append((server.read(peer: peer, messageIds: request.messageIds), server.unread))
          }

        case 7:
          // A dialog snapshot (getChats, getChat, sync sidecar) out of order with the stream.
          let hasPending = try database.dbWriter.read { db in
            try !ChatActivityItem.pendingCounts(db, chatId: chatId).isEmpty
          }
          try database.dbWriter.write { db in try saveSnapshot(db) }
          // With reads in flight the snapshot is ignored, so the stream state still stands.
          if !hasPending {
            lastSnapshot = server.unread
            updatesBehindSnapshot = deliveries.count
          }

        case 8:
          // A complete refill of one kind.
          let kind: ChatActivityItem.Kind = rng.int(2) == 0 ? .mention : .reaction
          let ids = server.unread.filter { $0.kind == kind }.map(\.messageId).sorted()
          let counts = ActivityCounts(mentions: server.count(.mention), reactions: server.count(.reaction))
          try database.dbWriter.write { db in
            try ChatActivityItem.replaceUnread(db, chatId: chatId, kind: kind, messageIds: ids, complete: true)
            var dialog = try dialog(db)
            try dialog.applyServerActivityCounts(db, counts)
            try dialog.update(db)
          }
          // The refill's counts can run ahead of queued updates like any snapshot.
          lastSnapshot = server.unread
          updatesBehindSnapshot = deliveries.count

        case 9:
          // A history page encoded from some earlier server state lands now. It may flag
          // messages that were read since.
          let state = pastStates[rng.int(pastStates.count)]
          let page = state.sorted().filter { _ in rng.int(2) == 0 }.map { key in
            InlineProtocol.Message.with {
              $0.id = key.messageId
              if key.kind == .mention { $0.unreadMention = true } else { $0.unreadReactions = true }
            }
          }
          try database.dbWriter.write { db in
            try ChatActivityItem.insertFromHistory(db, chatId: chatId, messages: page)
          }

        default:
          // Deliver the next update in order.
          guard !deliveries.isEmpty else { continue }
          let next = deliveries.removeFirst()
          try database.dbWriter.write { db in try next.update.apply(db) }
          lastSnapshot = next.snapshot
          updatesBehindSnapshot = max(0, updatesBehindSnapshot - 1)
      }
      pastStates.append(server.unread)

      // At every step the badge shows what the server last said, minus what this device has
      // already read but the server has not confirmed. A row a stale history page added can be
      // read here after the server already read it; until the echo lands it dips the count, so
      // then only the bounds are checked.
      try database.dbWriter.read { db in
        let dialog = try dialog(db)
        let pending = Set(
          try ChatActivityItem.filter(ChatActivityItem.Columns.chatId == chatId)
            .filter(ChatActivityItem.Columns.pendingRead == true)
            .fetchAll(db)
            .map { Key(messageId: $0.messageId, kind: $0.kind) }
        )
        for kind in ChatActivityItem.Kind.allCases {
          let shown = max(0, dialog.activityCount(kind) ?? 0)
          let serverCount = lastSnapshot.filter { $0.kind == kind }.count
          guard updatesBehindSnapshot == 0 else { continue }
          if pending.isSubset(of: lastSnapshot) {
            #expect(shown == lastSnapshot.subtracting(pending).filter { $0.kind == kind }.count, "seed \(seed) \(kind) \(trace)")
          } else {
            #expect(shown <= serverCount, "seed \(seed)")
          }
        }
      }
    }

    // Drain: the server answers every request, then every update arrives.
    for request in requests {
      deliveries.append((server.read(peer: peer, messageIds: request.messageIds), server.unread))
    }
    for next in deliveries {
      try database.dbWriter.write { db in try next.update.apply(db) }
    }

    // Rows only stale history added are still here; the user jumps to each, which reads it,
    // and the server's echo clears it.
    let leftovers = try database.dbWriter.write { db in
      let rows = try ChatActivityItem.unread(chatId: chatId).fetchAll(db)
      let stale = rows.filter { !server.unread.contains(Key(messageId: $0.messageId, kind: $0.kind)) }.map(\.messageId)
      try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: stale)
      return stale
    }
    if !leftovers.isEmpty {
      let echo = server.read(peer: peer, messageIds: leftovers)
      try database.dbWriter.write { db in try echo.apply(db) }
    }

    try database.dbWriter.read { db in
      let dialog = try dialog(db)
      #expect(dialog.unreadMentionsCount == server.count(.mention), "seed \(seed)")
      #expect(dialog.unreadReactionsCount == server.count(.reaction), "seed \(seed)")

      let local = try ChatActivityItem.filter(ChatActivityItem.Columns.chatId == chatId).fetchAll(db)
      #expect(local.allSatisfy { !$0.pendingRead }, "seed \(seed)")
      #expect(Set(local.map { Key(messageId: $0.messageId, kind: $0.kind) }) == server.unread, "seed \(seed)")
      // The @ button always jumps to the oldest unread mention or reply.
      let oldest = try ChatActivityItem.oldestUnread(db, chatId: chatId, kind: .mention)?.messageId
      #expect(oldest == server.unread.filter { $0.kind == .mention }.min()?.messageId, "seed \(seed)")
    }
  }
}

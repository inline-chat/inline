import Auth
import Foundation
import GRDB
import Logger
import RealtimeV2

/// Pushes reads made on this device to the server, like Telegram's
/// `ManagedSynchronizePeerReadStates`.
///
/// A read is pending while a dialog's `readInboxMaxId` is ahead of its `serverReadInboxMaxId`, so
/// it is stored with the read itself and survives a relaunch. Each chat has at most one request
/// in flight, and every request carries the newest local cursor when it is sent: a fast scroll
/// becomes one request plus one follow-up, and no read is dropped.
actor ReadStateSync {
  static let shared = ReadStateSync()

  private struct Loop {
    let generation: Int
    let task: Task<Void, Never>
  }

  private let log = Log.scoped("ReadStateSync")
  private var loops: [Int64: Loop] = [:]
  private var generation = 0
  /// Chats read across history not stored here: their count is fetched once the read is pushed.
  private var countValidations = Set<Int64>()

  /// Starts pushing a chat's reads, unless that is already running: a running push re-reads the
  /// cursor after each request. `validatingCount` asks the server for the chat's count afterwards,
  /// as Telegram does after a read across a hole.
  nonisolated func schedule(_ peer: Peer, validatingCount: Bool = false) {
    Task(priority: .utility) {
      if validatingCount { await self.requestCountValidation(peer) }
      await self.start(peer)
    }
  }

  private func requestCountValidation(_ peer: Peer) {
    countValidations.insert(Dialog.getDialogId(peerId: peer))
  }

  /// Pushes every read the server has not got, after a relaunch or a reconnect.
  func resumePending() async {
    guard AppDatabase.shared.isPersistent else { return }
    do {
      let peers = try await AppDatabase.shared.reader.read { db in try Dialog.pendingReadPeers(db) }
      for peer in peers { start(peer) }
    } catch {
      log.error("Failed to find reads to push", error: error)
    }
  }

  /// Marking a chat unread supersedes a read not sent yet: the server's read would clear the
  /// mark. A request already sent is ordered before the mark by the chat's transaction lane. The
  /// read stays on this device and goes out with the next read in this chat.
  func dropPending(_ peer: Peer) async {
    let dialogId = Dialog.getDialogId(peerId: peer)
    loops[dialogId]?.task.cancel()
    loops[dialogId] = nil
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard let pending = try Dialog.pendingReadMaxId(db, dialogId: dialogId) else { return }
        try Dialog.confirmServerRead(db, dialogId: dialogId, through: pending)
      }
    } catch {
      log.error("Failed to drop a read superseded by mark-unread", error: error)
    }
  }

  private func start(_ peer: Peer) {
    let dialogId = Dialog.getDialogId(peerId: peer)
    guard loops[dialogId] == nil else { return }
    generation &+= 1
    let generation = generation
    let task = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      await self.run(peer, dialogId: dialogId, generation: generation)
    }
    loops[dialogId] = Loop(generation: generation, task: task)
  }

  /// Push and release the slot without leaving the actor in between: a read scheduled while
  /// this loop is still registered is picked up by the loop, never dropped by `start`.
  private func run(_ peer: Peer, dialogId: Int64, generation: Int) async {
    await push(peer, dialogId: dialogId)
    finish(dialogId: dialogId, generation: generation)
  }

  private func finish(dialogId: Int64, generation: Int) {
    guard loops[dialogId]?.generation == generation else { return }
    loops[dialogId] = nil
  }

  private func push(_ peer: Peer, dialogId: Int64) async {
    var failures = 0
    while !Task.isCancelled {
      guard let account = try? Auth.shared.handle.beginAccountMutation() else { return }
      let target: Int64?
      do {
        target = try await AppDatabase.shared.reader.read { db in try Dialog.pendingReadMaxId(db, dialogId: dialogId) }
      } catch {
        log.error("Failed to read a pending read", error: error)
        return
      }
      guard !Task.isCancelled else { return }
      guard let target else {
        // Pushed. A read across a gap lowered the count only by the messages stored here; the
        // server's dialog at this same cursor has the real count (`saveFull` takes it).
        if countValidations.remove(dialogId) != nil {
          do {
            _ = try await Api.realtime.send(.getChat(peer: peer), expectedAccount: account)
          } catch {
            log.error("Failed to validate a chat's unread count", error: error)
          }
          // A read may have been scheduled while that ran; `start` left it to this loop.
          continue
        }
        return
      }

      do {
        _ = try await Api.realtime.send(.readMessages(peerId: peer, maxId: target), expectedAccount: account)
        try await confirm(dialogId: dialogId, through: target, account: account)
        failures = 0
      } catch is CancellationError {
        // A reconnect resumes it.
        return
      } catch where AutomaticReadRetryPolicy.shouldRetry(error) {
        failures += 1
        let delay = AutomaticReadRetryPolicy.delaySeconds(failureCount: failures, jitterUnit: Double.random(in: 0 ... 1))
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      } catch {
        // The server refused this read: retrying would loop forever. Telegram drops a rejected
        // push the same way. The next read in this chat carries the cursor again.
        log.error("Server rejected a read; not retrying it", error: error)
        try? await confirm(dialogId: dialogId, through: target, account: account)
      }
    }
  }

  /// The server answers a read with `UpdateReadMaxId`, or with nothing when it already had it
  /// (another device read further): either way it has this cursor now.
  private func confirm(dialogId: Int64, through maxId: Int64, account: AuthAccountMutationToken) async throws {
    try await AppDatabase.shared.dbWriter.write { db in
      try Auth.shared.handle.validateAccountMutation(account)
      try Dialog.confirmServerRead(db, dialogId: dialogId, through: maxId)
    }
  }
}

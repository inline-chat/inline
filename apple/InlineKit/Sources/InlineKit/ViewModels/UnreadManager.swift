import Foundation
import GRDB
import Logger

#if os(iOS)
import UIKit
#else
import AppKit
#endif

public final class UnreadManager: Sendable {
  public static let shared = UnreadManager()

  private let log = Log.scoped("UnreadManager", enableTracing: false)
  private static let readAllLocalCooldown: TimeInterval = 0.15
  private static let readAllRemoteCooldown: TimeInterval = 0.35

  private actor ReadAllGate {
    struct State {
      var lastLocalWriteAt: TimeInterval = 0
      var lastRemoteSendAt: TimeInterval = 0
      var remoteInFlight = false
    }

    private var stateByDialogId: [Int64: State] = [:]

    func begin(
      dialogId: Int64,
      now: TimeInterval,
      localCooldown: TimeInterval,
      remoteCooldown: TimeInterval
    ) -> (shouldWriteLocal: Bool, shouldSendRemote: Bool) {
      var state = stateByDialogId[dialogId] ?? State()

      let shouldWriteLocal = now - state.lastLocalWriteAt >= localCooldown
      if shouldWriteLocal {
        state.lastLocalWriteAt = now
      }

      let shouldSendRemote = state.remoteInFlight == false && now - state.lastRemoteSendAt >= remoteCooldown
      if shouldSendRemote {
        state.lastRemoteSendAt = now
        state.remoteInFlight = true
      }

      stateByDialogId[dialogId] = state
      return (shouldWriteLocal, shouldSendRemote)
    }

    func completeRemote(dialogId: Int64) {
      guard var state = stateByDialogId[dialogId] else { return }
      state.remoteInFlight = false
      stateByDialogId[dialogId] = state
    }
  }

  private let readAllGate = ReadAllGate()

  private init() {}

  private let apiClient = ApiClient.shared
  private let db = AppDatabase.shared

  private func sendReadMessagesToServer(peerId: Peer, maxId: Int64?) async {
    do {
      _ = try await Api.realtime.send(.readMessages(peerId: peerId, maxId: maxId))
    } catch {
      log.error("Realtime readMessages failed, falling back to HTTP route", error: error)
      do {
        _ = try await apiClient.readMessages(peerId: peerId, maxId: maxId)
      } catch {
        log.error("Failed to update remote server", error: error)
      }
    }
  }

  // This is called when chat opens initially
  public func readMessages(_ maxId: Int64, in peerId: Peer, chatId: Int64) {
    log.debug("readMessages")
    // TODO: update local DB with locally computed new unread count
    // let's just zero it, until later when we need to calculate exactly how many messages are unread still locally and
    // avoid applying old remote unread count, etc.

    // update server
    // TODO: add throttle
    Task {
      await sendReadMessagesToServer(peerId: peerId, maxId: maxId)
    }

#if os(iOS)
    NotificationCleanup.removeNotifications(threadId: "chat_\(chatId)", upToMessageId: maxId)
#endif
  }

  // Useful in context menu to mark all messages as read
  public func readAll(_ peerId: Peer, chatId: Int64) {
    log.debug("readAll")
    let localDialogId = Dialog.getDialogId(peerId: peerId)

    Task(priority: .userInitiated) {
      let now = Date().timeIntervalSinceReferenceDate
      let (shouldWriteLocal, shouldSendRemote) = await readAllGate.begin(
        dialogId: localDialogId,
        now: now,
        localCooldown: Self.readAllLocalCooldown,
        remoteCooldown: Self.readAllRemoteCooldown
      )

      if shouldWriteLocal {
        do {
          try await db.dbWriter.write { db in
            let hasUnread = (Column("unreadCount") > 0) || (Column("unreadMark") == true)
            try Dialog
              .filter(id: localDialogId)
              .filter(hasUnread)
              .updateAll(db, [
                Column("unreadCount").set(to: 0),
                Column("unreadMark").set(to: false)
              ])
          }
        } catch {
          log.error("Failed to update local DB with unread count", error: error)
        }
      }

      if shouldSendRemote {
        await sendReadMessagesToServer(peerId: peerId, maxId: nil)
        await readAllGate.completeRemote(dialogId: localDialogId)
      }
    }

#if os(iOS)
    NotificationCleanup.removeNotifications(threadId: "chat_\(chatId)", upToMessageId: nil)
#endif
  }
}

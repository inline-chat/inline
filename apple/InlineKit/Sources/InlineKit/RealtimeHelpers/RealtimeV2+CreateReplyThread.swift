import Foundation
import Logger
import RealtimeV2

public extension RealtimeV2 {
  /// Starts creating `parentMessageId`'s reply thread under a cached reserved id and
  /// returns that id once the local thread exists, so it can be opened right away.
  ///
  /// Returns nil when no reservation is cached or local admission fails; callers then
  /// create the thread directly. Falling back is safe here, unlike top-level creation:
  /// the server returns the one existing reply thread for a parent message.
  func createReplyThreadLocally(parentChatId: Int64, parentMessageId: Int64) async -> Int64? {
    guard parentChatId > 0, parentMessageId > 0,
          let reservedChatId = await ReservedChatIDPool.shared.consumeCached(realtimeV2: self)
    else { return nil }

    let transaction = CreateSubthreadTransaction.createSubthread(
      parentChatId: parentChatId,
      parentMessageId: parentMessageId,
      reservedChatId: reservedChatId
    )
    guard await sendQueuedIfAccepted(transaction) != nil else {
      Log.scoped("RealtimeV2.CreateReplyThread").warning("Queued reply-thread creation was not admitted")
      return nil
    }
    return reservedChatId
  }
}

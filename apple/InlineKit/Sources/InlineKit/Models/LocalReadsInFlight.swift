import InlineCompat

/// Dialogs this device has marked read locally while the server has not confirmed it yet.
///
/// "Mark all read" clears the local count at once and moves `readInboxMaxId` only when the
/// server's `UpdateReadMaxId` lands. Until then a server dialog computed before the read still
/// carries the old count at the same read cursor, and taking it would show the chat unread again
/// for a round trip. Telegram likewise skips re-syncing a peer's counter while its own read
/// operation for that peer is running. Kept in memory: a relaunch has no read in flight.
enum LocalReadsInFlight {
  private static let reads = Mutex<[Int64: Set<String>]>([:])

  static func begin(dialogID: Int64, intentID: String) {
    reads.withLock { $0[dialogID, default: []].insert(intentID) }
  }

  static func end(dialogID: Int64, intentID: String) {
    reads.withLock { reads in
      reads[dialogID]?.remove(intentID)
      if reads[dialogID]?.isEmpty == true { reads[dialogID] = nil }
    }
  }

  static func contains(dialogID: Int64) -> Bool {
    reads.withLock { $0[dialogID] != nil }
  }
}

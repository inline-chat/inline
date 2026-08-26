import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Open Chats cleanup")
struct OpenChatsCleanupTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("Manual cleanup requires both quiet periods")
  func manualQuietPeriods() {
    let policy = OpenChatsCleanupPolicy.manual

    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-6 * 60 * 60),
      lastActivityAt: now.addingTimeInterval(-3 * 60 * 60),
      latestOwnMessageAt: nil,
      isEmptyUntitled: false
    ))
    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-(6 * 60 * 60 - 1)),
      lastActivityAt: now.addingTimeInterval(-4 * 60 * 60),
      latestOwnMessageAt: nil,
      isEmptyUntitled: false
    ) == false)
    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-7 * 60 * 60),
      lastActivityAt: now.addingTimeInterval(-(3 * 60 * 60 - 1)),
      latestOwnMessageAt: nil,
      isEmptyUntitled: false
    ) == false)
  }

  @Test("Empty untitled threads are immediately eligible")
  func emptyUntitledThread() {
    #expect(OpenChatsCleanupPolicy.manual.shouldClose(
      now: now,
      openedAt: now,
      lastActivityAt: nil,
      latestOwnMessageAt: nil,
      isEmptyUntitled: true
    ))
  }

  @Test("Automatic cleanup preserves its opened-or-sent timeout")
  func automaticTimeout() {
    let policy = OpenChatsCleanupPolicy.automatic(timeout: 12 * 60 * 60)

    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-13 * 60 * 60),
      lastActivityAt: now,
      latestOwnMessageAt: now.addingTimeInterval(-12 * 60 * 60),
      isEmptyUntitled: false
    ))
    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-13 * 60 * 60),
      lastActivityAt: nil,
      latestOwnMessageAt: now.addingTimeInterval(-60 * 60),
      isEmptyUntitled: false
    ) == false)
  }

  @Test("Commit closes stale chats and selects every visually empty folder")
  func commitSelectsEmptyFolders() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      try DialogFolder(id: 1, title: nil, order: "a").insert(db)
      try DialogFolder(id: 2, title: "Named", order: "b").insert(db)
      try DialogFolder(id: 3, title: "Active", order: "c").insert(db)
      try DialogFolder(id: 4, title: "Closed membership", order: "d").insert(db)
      try DialogFolder(id: 5, title: "Becomes empty", order: "e").insert(db)
      try DialogFolder(id: 6, title: "Pinned", order: "f", pinnedOrder: "p").insert(db)

      try seedDialog(
        db,
        chatID: 30,
        folderID: 3,
        open: true,
        openedAt: now
      )
      try seedDialog(
        db,
        chatID: 40,
        folderID: 4,
        open: false,
        openedAt: nil
      )
      try seedDialog(
        db,
        chatID: 50,
        folderID: 5,
        open: true,
        openedAt: now.addingTimeInterval(-7 * 60 * 60)
      )
      try seedDialog(
        db,
        chatID: 60,
        folderID: 6,
        open: true,
        openedAt: now.addingTimeInterval(-7 * 60 * 60)
      )
    }

    let candidates = try await OpenChatsCleanup.candidates(
      in: database,
      policy: .manual,
      now: now,
      currentUserID: 99
    )
    #expect(candidates.map(\.peer) == [.thread(id: 50)])

    let commit = try await OpenChatsCleanup.commit(
      in: database,
      policy: .manual,
      now: now,
      currentUserID: 99,
      dialogIDs: candidates.map(\.dialogID)
    )

    #expect(commit.closedPeers == [.thread(id: 50)])
    #expect(commit.emptyFolderIDs == [1, 2, 4, 5])

    try await database.reader.read { db in
      let closed = try #require(try Dialog.get(peerId: .thread(id: 50)).fetchOne(db))
      let protected = try #require(try Dialog.get(peerId: .thread(id: 60)).fetchOne(db))
      #expect(closed.open == false)
      #expect(closed.openedDate == nil)
      #expect(closed.order == nil)
      #expect(protected.open == true)
      // Server mutations own authoritative folder removal and ungrouping.
      #expect(try DialogFolder.fetchCount(db) == 6)
    }
  }

  private func seedDialog(
    _ db: Database,
    chatID: Int64,
    folderID: Int64,
    open: Bool,
    openedAt: Date?
  ) throws {
    try Chat(
      id: chatID,
      date: now,
      type: .thread,
      title: "Thread \(chatID)",
      spaceId: nil
    ).insert(db)

    var dialog = Dialog(
      id: Dialog.getDialogId(peerId: .thread(id: chatID)),
      peerUserId: nil,
      peerThreadId: chatID,
      spaceId: nil,
      unreadCount: 0,
      readInboxMaxId: nil,
      readOutboxMaxId: nil,
      pinned: false,
      draftMessage: nil,
      archived: false,
      chatId: chatID,
      unreadMark: false,
      notificationSettings: nil,
      open: open,
      openedDate: openedAt,
      order: open ? "o\(chatID)" : nil,
      chatListHidden: nil
    )
    dialog.folderId = folderID
    try dialog.insert(db)
  }
}

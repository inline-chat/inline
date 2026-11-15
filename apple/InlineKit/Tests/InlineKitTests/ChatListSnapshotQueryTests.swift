import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Chat-list snapshot query")
struct ChatListSnapshotQueryTests {
  @Test("Single-line text matches the split-and-join normalization")
  func singleLineTextMatchesReference() {
    let samples: [String?] = [
      nil, "", " ", "\n\n", "Amy", "Amy Lee", " Amy", "Amy ", "Amy  Lee", "Amy\tLee",
      "Hey there,\nthis is\n\n a  message ", "\r\nline\r\n", "a\u{00A0}b", "a\u{2028}b",
      "a\u{0085}b", "a\u{3000}b", "a \u{0301}b", "👋🏽 hi", "x\u{000B}y\u{000C}z",
      "مرحبا  بك", String(repeating: "word ", count: 200),
    ]
    for sample in samples {
      #expect(ChatListDatabaseQuery.singleLineText(sample) == referenceSingleLineText(sample))
    }
  }

  @Test("Snapshots without openedDate are not invalidated by opening a chat")
  @MainActor
  func openedDateWritesSkipNarrowSnapshots() async throws {
    let narrow = try await countValuesAfterOpenedDateWrite(includeOpenedDate: false)
    #expect(narrow.values == 2)
    #expect(narrow.last?.openedDate == nil)
    #expect(narrow.last?.timestampText == nil)
    #expect(narrow.last?.unreadCount == 3)

    // Control: the same writes refresh a snapshot that reads openedDate.
    let full = try await countValuesAfterOpenedDateWrite(includeOpenedDate: true)
    #expect(full.values == 3)
    #expect(full.last?.openedDate != nil)
  }

  @MainActor
  private func countValuesAfterOpenedDateWrite(
    includeOpenedDate: Bool
  ) async throws -> (values: Int, last: ChatListItemSnapshot?) {
    let database = AppDatabase.empty()
    let userID: Int64 = 910
    let chatID: Int64 = 911
    let dialogID = Dialog.getDialogId(peerUserId: userID)

    try await database.dbWriter.write { db in
      try User(id: userID, email: nil, firstName: "Amy").insert(db)
      try Chat(
        id: chatID,
        date: Date(timeIntervalSince1970: 1_790_000_000),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: userID
      ).insert(db)
      var dialog = Dialog.previewDm
      dialog.id = dialogID
      dialog.peerUserId = userID
      dialog.chatId = chatID
      dialog.open = true
      try dialog.insert(db)
    }

    let recorder = CountingRecorder()
    let cancellable = ValueObservation
      .trackingConstantRegion { db in
        try ChatListDatabaseQuery.fetchSnapshots(
          db,
          spaceID: nil,
          includeSpaceChatsInHome: true,
          translationLanguage: "en",
          includeOpenedDate: includeOpenedDate,
          includeTimestampText: false
        )
      }
      .start(
        in: database.dbWriter,
        scheduling: .immediate,
        onError: { _ in },
        onChange: recorder.record
      )
    defer { cancellable.cancel() }

    try await database.dbWriter.write { db in
      try db.execute(
        sql: #"UPDATE "dialog" SET "openedDate" = ? WHERE "id" = ?"#,
        arguments: [Date(), dialogID]
      )
    }
    // Let a fetch triggered by that write publish before the next write, so
    // two changes cannot coalesce into one value.
    try await Task.sleep(for: .milliseconds(200))
    try await database.dbWriter.write { db in
      try db.execute(
        sql: #"UPDATE "dialog" SET "unreadCount" = 3 WHERE "id" = ?"#,
        arguments: [dialogID]
      )
    }
    for _ in 0 ..< 200 where recorder.last?.unreadCount != 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    return (recorder.values, recorder.last)
  }

  private func referenceSingleLineText(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { $0.isEmpty == false }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

private final class CountingRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var latest: ChatListItemSnapshot?

  var values: Int { lock.withLock { count } }
  var last: ChatListItemSnapshot? { lock.withLock { latest } }

  func record(_ snapshots: [ChatListItemSnapshot]) {
    lock.withLock {
      count += 1
      latest = snapshots.first
    }
  }
}

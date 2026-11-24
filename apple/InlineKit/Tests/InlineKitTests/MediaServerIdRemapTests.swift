import Foundation
import GRDB
import Testing

@testable import InlineKit

/// Mac Tip 7416 failed sends after the upload finished: moving a photo to its server ID
/// tripped the photoId foreign key (Sentry INLINE-IOS-MACOS-53S/53T).
@Suite("Media server ID remap")
struct MediaServerIdRemapTests {
  private let chatId: Int64 = 910
  private let userId: Int64 = 1
  private let tempPhotoId: Int64 = -77
  private let serverPhotoId: Int64 = 39_418

  private func makeDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try User(id: userId, email: "user@example.com", firstName: "User", lastName: nil, username: "user")
        .insert(db)
      try Chat(id: chatId, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Thread", spaceId: nil)
        .insert(db)
    }
    return queue
  }

  private func seedMessage(_ db: Database, id: Int64, photoId: Int64) throws {
    var message = Message(
      messageId: id,
      fromId: userId,
      date: Date(timeIntervalSince1970: TimeInterval(id)),
      text: "message-\(id)",
      peerUserId: nil,
      peerThreadId: chatId,
      chatId: chatId
    )
    message.photoId = photoId
    try message.saveMessage(db)
  }

  private func photoIds(_ db: Database) throws -> [Int64?] {
    try Int64?.fetchAll(db, sql: "SELECT photoId FROM message ORDER BY messageId")
  }

  @Test("moves every message and URL preview with the photo, from a stale snapshot, idempotently")
  func remapsAllReferences() throws {
    let dbQueue = try makeDB()
    try dbQueue.write { db in
      var photo = Photo(photoId: tempPhotoId, format: .jpeg)
      try photo.insert(db)
      try seedMessage(db, id: 1, photoId: tempPhotoId)
      try seedMessage(db, id: 2, photoId: tempPhotoId)
      try db.execute(
        sql: "INSERT INTO urlPreview (url, photoId) VALUES (?, ?)",
        arguments: ["https://inline.chat", tempPhotoId]
      )
      // The caller's copy still carries an older temporary ID.
      var stale = photo
      stale.photoId = -1

      try AppDatabase.updatePhotoWithServerId(db, localPhoto: stale, serverId: serverPhotoId)
      // A repeated completion is a no-op.
      try AppDatabase.updatePhotoWithServerId(db, localPhoto: photo, serverId: serverPhotoId)
    }

    let (messages, preview, photos, violations) = try dbQueue.read { db in
      (
        try photoIds(db),
        try Int64.fetchOne(db, sql: "SELECT photoId FROM urlPreview"),
        try Photo.fetchAll(db).map(\.photoId),
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
      )
    }
    #expect(messages == [serverPhotoId, serverPhotoId])
    #expect(preview == serverPhotoId)
    #expect(photos == [serverPhotoId])
    #expect(violations == 0)
  }

  @Test("points references at the server photo when its echo was stored first")
  func reusesStoredServerPhoto() throws {
    let dbQueue = try makeDB()
    try dbQueue.write { db in
      var local = Photo(photoId: tempPhotoId, format: .jpeg)
      try local.insert(db)
      var echoed = Photo(photoId: serverPhotoId, format: .jpeg)
      try echoed.insert(db)
      try seedMessage(db, id: 1, photoId: tempPhotoId)

      try AppDatabase.updatePhotoWithServerId(db, localPhoto: local, serverId: serverPhotoId)
    }

    let (messages, violations) = try dbQueue.read { db in
      (try photoIds(db), try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count)
    }
    #expect(messages == [serverPhotoId])
    #expect(violations == 0)
  }
}

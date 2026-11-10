import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Get chat peer user persistence")
struct GetChatPeerUserPersistenceTests {
  @Test("a full profile clears a previously shared time zone after access is revoked")
  func clearsRevokedTimeZone() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      var existing = User(id: 202, email: nil, firstName: "Peer")
      existing.timeZone = "Asia/Tokyo"
      try existing.insert(db)
      let redacted = InlineProtocol.User.with {
        $0.id = 202
        $0.firstName = "Peer"
        $0.min = false
      }

      #expect(try GetChatTransaction.repairPeerProfilePhoto(redacted, in: db))
      #expect(try User.fetchOne(db, id: 202)?.timeZone == nil)
      #expect(try GetChatTransaction.repairPeerProfilePhoto(redacted, in: db) == false)
    }
  }

  @Test("minimal profile omission retains the cached time zone")
  func minimalOmissionKeepsTimeZone() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      var existing = User(id: 203, email: nil, firstName: "Peer")
      existing.timeZone = "Asia/Tokyo"
      try existing.insert(db)
      let minimal = InlineProtocol.User.with {
        $0.id = 203
        $0.firstName = "Peer"
        $0.min = true
      }

      #expect(try GetChatTransaction.repairPeerProfilePhoto(minimal, in: db) == false)
      #expect(try User.fetchOne(db, id: 203)?.timeZone == "Asia/Tokyo")
    }
  }

  @Test("peer profile photo repairs the existing user")
  func repairsExistingProfilePhoto() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      var existing = User(id: 200, email: "peer@example.com", firstName: "Peer")
      existing.profileCdnUrl = "https://cdn.inline.chat/old.jpg"
      existing.profileFileUniqueId = "old-profile"
      existing.profileLocalPath = "old-cache.jpg"
      try existing.insert(db)

      let peer = InlineProtocol.User.with {
        $0.id = 200
        $0.firstName = "Peer"
        $0.min = false
        $0.profilePhoto = .with {
          $0.cdnURL = "https://cdn.inline.chat/new.jpg?token=signed"
          $0.fileUniqueID = "new-profile"
        }
      }

      #expect(try GetChatTransaction.repairPeerProfilePhoto(peer, in: db))

      let saved = try #require(try User.fetchOne(db, id: 200))
      #expect(saved.profileCdnUrl == "https://cdn.inline.chat/new.jpg?token=signed")
      #expect(saved.profileFileUniqueId == "new-profile")
      #expect(saved.profileLocalPath == nil)

      let staleLegacyPhoto = File(
        id: "old-file",
        fileUniqueId: "old-profile",
        fileType: .photo,
        fileName: "old.jpg",
        uploading: false,
        fileSize: 1,
        temporaryUrl: "https://cdn.inline.chat/old.jpg",
        temporaryUrlExpiresAt: nil,
        width: 32,
        height: 32,
        localPath: nil,
        mimeType: "image/jpeg"
      )
      #expect(
        UserInfo(user: saved, profilePhotos: [staleLegacyPhoto]).stableAvatarIdentity
          == "unique:new-profile"
      )
      #expect(try GetChatTransaction.repairPeerProfilePhoto(peer, in: db) == false)
    }
  }

  @Test("matching no-photo state does not write the peer user")
  func skipsMatchingNoPhotoUser() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      let existing = User(id: 201, email: "peer@example.com", firstName: "Peer")
      try existing.insert(db)

      let peer = InlineProtocol.User.with {
        $0.id = 201
        $0.firstName = "Peer"
        $0.min = false
      }

      #expect(try GetChatTransaction.repairPeerProfilePhoto(peer, in: db) == false)
    }
  }
}

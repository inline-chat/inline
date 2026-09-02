import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("User protocol save")
struct UserProtocolSaveTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("V3 API user preserves compact profile photo")
  func apiUserPreservesCompactProfilePhoto() {
    let protocolUser = InlineProtocol.User.with {
      $0.id = 102
      $0.firstName = "Photo"
      $0.min = true
      $0.profilePhoto = .with {
        $0.cdnURL = "https://cdn.inline.chat/profile.jpg?token=signed"
        $0.fileUniqueID = "profile-unique-102"
      }
    }

    let apiUser = ApiUser(from: protocolUser)

    #expect(apiUser.photo == nil)
    #expect(apiUser.profilePhoto?.cdnURL == "https://cdn.inline.chat/profile.jpg?token=signed")
    #expect(apiUser.profilePhoto?.fileUniqueID == "profile-unique-102")
    #expect(apiUser.avatarURL == URL(string: "https://cdn.inline.chat/profile.jpg?token=signed"))
    #expect(apiUser.avatarFileUniqueID == "profile-unique-102")
    #expect(apiUser.hasConfiguredProfilePhoto)
  }

  @Test("V3 API user without a profile photo preserves no-photo state")
  func apiUserPreservesNoPhotoState() {
    let apiUser = ApiUser(from: .with {
      $0.id = 104
      $0.firstName = "Initials"
      $0.min = true
    })

    #expect(apiUser.photo == nil)
    #expect(apiUser.profilePhoto == nil)
    #expect(apiUser.avatarURL == nil)
    #expect(apiUser.avatarFileUniqueID == nil)
    #expect(apiUser.hasConfiguredProfilePhoto == false)
  }

  @Test("compact API photo is persisted without fabricated file metadata")
  func compactApiPhotoPersistsToNewUser() throws {
    let dbQueue = try makeInMemoryDB()
    let apiUser = ApiUser(from: .with {
      $0.id = 103
      $0.firstName = "Persisted"
      $0.min = true
      $0.profilePhoto = .with {
        $0.cdnURL = "https://cdn.inline.chat/persisted.jpg?token=signed"
        $0.fileUniqueID = "profile-unique-103"
      }
    })

    try dbQueue.write { db in
      let saved = try apiUser.saveFull(db)

      #expect(saved.profileCdnUrl == "https://cdn.inline.chat/persisted.jpg?token=signed")
      #expect(saved.profileFileUniqueId == "profile-unique-103")
      #expect(saved.profileFileId == nil)
      #expect(try File.filter(Column("profileForUserId") == 103).fetchCount(db) == 0)
    }
  }

  @Test("full protocol user clears omitted optional profile fields")
  func fullUserClearsOmittedProfileFields() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      var existing = User(
        id: 100,
        email: "old@example.com",
        firstName: "Old",
        lastName: "Name",
        username: "oldhandle",
        bio: "Old bio"
      )
      existing.timeZone = "Asia/Tehran"
      try existing.insert(db)

      var protocolUser = InlineProtocol.User()
      protocolUser.id = 100
      protocolUser.firstName = "New"
      protocolUser.min = false

      _ = try User.save(db, user: protocolUser)

      let saved = try #require(try User.fetchOne(db, id: 100))
      #expect(saved.firstName == "New")
      #expect(saved.lastName == nil)
      #expect(saved.bio == nil)
      #expect(saved.username == nil)
      #expect(saved.timeZone == nil)
    }
  }

  @Test("min protocol user preserves omitted profile fields")
  func minUserPreservesOmittedProfileFields() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      var existing = User(
        id: 101,
        email: "old@example.com",
        firstName: "Old",
        lastName: "Name",
        username: "oldhandle",
        bio: "Old bio"
      )
      existing.pendingSetup = false
      existing.online = true
      existing.lastOnline = Date(timeIntervalSince1970: 123)
      existing.timeZone = "Asia/Tehran"
      try existing.insert(db)

      var protocolUser = InlineProtocol.User()
      protocolUser.id = 101
      protocolUser.firstName = "Mini"
      protocolUser.min = true

      _ = try User.save(db, user: protocolUser)

      let saved = try #require(try User.fetchOne(db, id: 101))
      #expect(saved.firstName == "Mini")
      #expect(saved.lastName == "Name")
      #expect(saved.bio == "Old bio")
      #expect(saved.username == "oldhandle")
      #expect(saved.pendingSetup == false)
      #expect(saved.online == true)
      #expect(saved.lastOnline == Date(timeIntervalSince1970: 123))
      #expect(saved.timeZone == "Asia/Tehran")
    }
  }
}

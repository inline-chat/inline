import Foundation
import GRDB
import Testing
@testable import InlineKit
import InlineProtocol

@Suite("User profile cache")
struct UserProfileCacheTests {
  @Test("late avatar downloads cannot replace a changed or removed profile photo", arguments: [0, 1, 2])
  func rejectsStaleDownload(change: Int) async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      var current = User(id: 1, email: nil, firstName: "User")
      current.profileFileUniqueId = change == 0 ? "new-photo" : "old-photo"
      current.profileCdnUrl = change == 1 ? "https://example.com/new.jpg" : "https://example.com/old.jpg"
      current.profileLocalPath = "new-cache.jpg"
      if change == 2 {
        current.profileFileUniqueId = nil
        current.profileCdnUrl = nil
        current.profileLocalPath = nil
      }
      try current.save(db)
      let stored = try #require(try User.fetchOne(db, id: 1))

      #expect(throws: (any Error).self) {
        try User.storeCachedProfilePhoto(
          db,
          userId: 1,
          localPath: "late-old-download.jpg",
          expectedSourceURL: URL(string: "https://example.com/old.jpg"),
          expectedAvatarIdentity: "unique:old-photo"
        )
      }
      #expect(try User.fetchOne(db, id: 1) == stored)
    }
  }

  @Test("matching avatar download updates the cache and returns the superseded path")
  func acceptsCurrentDownload() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      var current = User(id: 1, email: nil, firstName: "User")
      current.profileFileUniqueId = "current-photo"
      current.profileCdnUrl = "https://example.com/current.jpg"
      current.profileLocalPath = "previous-cache.jpg"
      try current.save(db)

      let previousPath = try User.storeCachedProfilePhoto(
        db,
        userId: 1,
        localPath: "current-cache.jpg",
        expectedSourceURL: current.getRemoteURL(),
        expectedAvatarIdentity: current.stableAvatarIdentity
      )
      #expect(previousPath == "previous-cache.jpg")
      #expect(try User.fetchOne(db, id: 1)?.profileLocalPath == "current-cache.jpg")
    }
  }

  @Test("a photo identity known only from the legacy photo File admits its download")
  func acceptsLegacyFileIdentity() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      var current = User(id: 1, email: nil, firstName: "User")
      current.profileCdnUrl = "https://example.com/legacy.jpg"
      try current.save(db)
      try legacyProfilePhoto(userId: 1, uniqueId: "legacy-photo").insert(db)

      // The view resolves its identity through UserInfo, which falls back to the File.
      let userInfo = try #require(try User.userInfoQuery().filter(Column("id") == 1).fetchOne(db))
      #expect(current.stableAvatarIdentity == nil)
      #expect(userInfo.stableAvatarIdentity == "unique:legacy-photo")

      _ = try User.storeCachedProfilePhoto(
        db,
        userId: 1,
        localPath: "legacy-cache.jpg",
        expectedSourceURL: current.getRemoteURL(),
        expectedAvatarIdentity: userInfo.stableAvatarIdentity
      )
      #expect(try User.fetchOne(db, id: 1)?.profileLocalPath == "legacy-cache.jpg")
    }
  }

  @Test("a legacy photo File does not admit a different photo", arguments: [
    (userPhoto: String?.none, expected: "unique:other-photo"),
    // A User-level identity replaces the File's, as it does in UserInfo.
    (userPhoto: "new-photo", expected: "unique:legacy-photo"),
  ])
  func rejectsOtherPhotoWithLegacyFile(userPhoto: String?, expected: String) async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      var current = User(id: 1, email: nil, firstName: "User")
      current.profileFileUniqueId = userPhoto
      current.profileCdnUrl = "https://example.com/legacy.jpg"
      try current.save(db)
      try legacyProfilePhoto(userId: 1, uniqueId: "legacy-photo").insert(db)
      let stored = try #require(try User.fetchOne(db, id: 1))

      #expect(throws: (any Error).self) {
        try User.storeCachedProfilePhoto(
          db,
          userId: 1,
          localPath: "other-cache.jpg",
          expectedSourceURL: current.getRemoteURL(),
          expectedAvatarIdentity: expected
        )
      }
      #expect(try User.fetchOne(db, id: 1) == stored)
    }
  }

  @Test("full user without a profile photo clears cached photo fields")
  func clearsPhotoForFullUser() async throws {
    let database = AppDatabase.empty()
    var existing = User(id: 1, email: "user@example.com", firstName: "User")
    existing.profileCdnUrl = "https://example.com/avatar.jpg"
    existing.profileFileUniqueId = "old-unique"
    existing.profileLocalPath = "cached.jpg"
    let storedExisting = existing
    try await database.dbWriter.write { db in try storedExisting.save(db) }

    let protocolUser = InlineProtocol.User.with {
      $0.id = 1
      $0.firstName = "User"
      $0.min = false
    }
    let saved = try await database.dbWriter.write { db in
      try User.save(db, user: protocolUser)
    }

    #expect(saved.profileCdnUrl == nil)
    #expect(saved.profileFileUniqueId == nil)
    #expect(saved.profileLocalPath == nil)
  }

  @Test("invalidates local cache when unique photo id changes")
  func invalidatesForUniqueIdChange() {
    var user = User(id: 1, email: "user@example.com", firstName: "User")
    user.profileFileUniqueId = "old-unique"
    user.profileFileId = "old-file"
    user.profileLocalPath = "cached.jpg"

    #expect(user.shouldInvalidateLocalCache(newFileUniqueId: "new-unique", newFileId: "old-file"))
  }

  @Test("invalidates local cache when file id changes without unique id")
  func invalidatesForFileIdChangeWithoutUniqueId() {
    var user = User(id: 1, email: "user@example.com", firstName: "User")
    user.profileFileId = "old-file"
    user.profileLocalPath = "cached.jpg"

    #expect(user.shouldInvalidateLocalCache(newFileUniqueId: nil, newFileId: "new-file"))
  }

  @Test("keeps local cache when profile identity is unchanged")
  func keepsCacheForSameIdentity() {
    var user = User(id: 1, email: "user@example.com", firstName: "User")
    user.profileFileUniqueId = "same-unique"
    user.profileFileId = "same-file"
    user.profileLocalPath = "cached.jpg"

    #expect(user.shouldInvalidateLocalCache(newFileUniqueId: "same-unique", newFileId: "other-file") == false)
  }

  private func legacyProfilePhoto(userId: Int64, uniqueId: String) -> File {
    var file = File(
      id: "legacy-file",
      fileUniqueId: uniqueId,
      fileType: .photo,
      fileName: "avatar.jpg",
      uploading: false,
      fileSize: nil,
      temporaryUrl: nil,
      temporaryUrlExpiresAt: nil,
      width: nil,
      height: nil,
      localPath: nil,
      mimeType: "image/jpeg"
    )
    file.profileForUserId = userId
    return file
  }
}

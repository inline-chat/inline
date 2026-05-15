import Testing
@testable import InlineKit

@Suite("User profile cache")
struct UserProfileCacheTests {
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
}

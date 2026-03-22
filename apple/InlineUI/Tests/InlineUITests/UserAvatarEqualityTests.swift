import Foundation
import InlineKit
import Testing

@testable import InlineUI

@Suite("User avatar equality")
struct UserAvatarEqualityTests {
  @Test("same photo identity with refreshed signed URL remains equal")
  @MainActor
  func samePhotoIdentityWithRefreshedURL() {
    var userA = User(id: 42, email: "avatar@example.com", firstName: "Avatar")
    userA.profileFileUniqueId = "profile-unique-1"
    userA.profileFileId = "profile-file-1"
    userA.profileCdnUrl = "https://cdn.inline.chat/avatar.jpg?token=old"

    var userB = userA
    userB.profileCdnUrl = "https://cdn.inline.chat/avatar.jpg?token=new"

    let lhs = UserAvatar(userInfo: UserInfo(user: userA), size: 32)
    let rhs = UserAvatar(userInfo: UserInfo(user: userB), size: 32)

    #expect(lhs == rhs)
  }

  @Test("different photo identity is not equal")
  @MainActor
  func differentPhotoIdentityIsNotEqual() {
    var userA = User(id: 42, email: "avatar@example.com", firstName: "Avatar")
    userA.profileFileUniqueId = "profile-unique-1"
    userA.profileFileId = "profile-file-1"

    var userB = userA
    userB.profileFileUniqueId = "profile-unique-2"

    let lhs = UserAvatar(userInfo: UserInfo(user: userA), size: 32)
    let rhs = UserAvatar(userInfo: UserInfo(user: userB), size: 32)

    #expect(lhs != rhs)
  }
}

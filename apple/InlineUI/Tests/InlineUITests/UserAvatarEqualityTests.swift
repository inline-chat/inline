import Foundation
import InlineKit
import InlineProtocol
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

  @Test("explicit local avatar URL is preferred over the model cache path")
  @MainActor
  func explicitLocalAvatarURLIsPreferred() {
    var user = User(id: 42, email: "avatar@example.com", firstName: "Avatar")
    user.profileLocalPath = "unavailable-in-extension.jpg"
    user.profileCdnUrl = "https://cdn.inline.chat/avatar.jpg"
    let sharedAvatarURL = URL(fileURLWithPath: "/dev/null")

    let avatar = UserAvatar(
      user: user,
      size: 32,
      cacheRemoteAvatar: false,
      localAvatarURL: sharedAvatarURL
    )

    #expect(avatar.localUrl == sharedAvatarURL)
    #expect(avatar.remoteUrl == URL(string: "https://cdn.inline.chat/avatar.jpg"))
  }

  @Test("API user preserves public-search photo identity and URL")
  @MainActor
  func apiUserPreservesSearchPhoto() throws {
    var user = try JSONDecoder().decode(ApiUser.self, from: Data(#"""
      {
        "id": 42,
        "firstName": "Avatar",
        "lastName": "Person",
        "date": 1,
        "username": "avatar",
        "photo": [{
          "fileUniqueId": "profile-unique-1",
          "width": 128,
          "height": 128,
          "fileSize": 4096,
          "mimeType": "image/jpeg",
          "temporaryUrl": "https://cdn.inline.chat/avatar.jpg?token=signed"
        }]
      }
      """#.utf8))
    user.profilePhoto = ApiUserProfilePhotoReference(
      cdnURL: "https://cdn.inline.chat/v3-avatar.jpg?token=new",
      fileUniqueID: "profile-unique-v3"
    )

    let avatar = UserAvatar(apiUser: user, size: 32, cacheRemoteAvatar: false)

    // A legacy response remains authoritative when both representations are present.
    #expect(avatar.stableAvatarIdentity == "unique:profile-unique-1")
    #expect(avatar.remoteUrl == URL(string: "https://cdn.inline.chat/avatar.jpg?token=signed"))
    #expect(avatar.hasConfiguredPhoto)
  }

  @Test("V3 search user renders its compact profile photo")
  @MainActor
  func protocolApiUserPreservesSearchPhoto() {
    let user = ApiUser(from: InlineProtocol.User.with {
      $0.id = 43
      $0.firstName = "Realtime"
      $0.min = true
      $0.profilePhoto = .with {
        $0.cdnURL = "https://cdn.inline.chat/realtime.jpg?token=signed"
        $0.fileUniqueID = "profile-unique-v3"
      }
    })

    let avatar = UserAvatar(apiUser: user, size: 32, cacheRemoteAvatar: false)

    #expect(avatar.stableAvatarIdentity == "unique:profile-unique-v3")
    #expect(avatar.remoteUrl == URL(string: "https://cdn.inline.chat/realtime.jpg?token=signed"))
    #expect(avatar.hasConfiguredPhoto)
  }
}

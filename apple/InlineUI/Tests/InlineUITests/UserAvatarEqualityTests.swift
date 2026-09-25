import Foundation
import InlineKit
import InlineProtocol
import Kingfisher
import Testing
#if os(macOS)
import AppKit
#endif

@testable import InlineUI

@Suite("User avatar equality")
struct UserAvatarEqualityTests {
  @Test("a replaced local photo refreshes the view and its processed image cache")
  @MainActor
  func localPhotoReplacementInvalidatesAvatar() {
    var oldUser = User(id: 42, email: nil, firstName: "Avatar")
    oldUser.profileFileUniqueId = "current-photo"
    let previous = UserAvatar(user: oldUser, localAvatarURL: URL(fileURLWithPath: "/dev/null"))
    let replacement = UserAvatar(user: oldUser, localAvatarURL: URL(fileURLWithPath: "/dev/zero"))
    let remote = UserAvatar(user: oldUser)

    #expect(previous != replacement)
    #expect(previous.avatarCacheKey != replacement.avatarCacheKey)
    #expect(previous != remote)
    #expect(previous.avatarCacheKey != remote.avatarCacheKey)
  }

  @Test("sidebar, toolbar and chat info share the same photo source cache")
  @MainActor
  func allAvatarSizesShareSource() {
    var user = User(id: 42, email: nil, firstName: "Avatar")
    user.profileFileUniqueId = "current-photo"
    user.profileCdnUrl = "https://cdn.inline.chat/current.jpg"
    let sidebar = UserAvatar(user: user, size: 22)
    let toolbar = UserAvatar(userInfo: UserInfo(user: user), size: 30)
    let chatInfo = UserAvatar(userInfo: UserInfo(user: user), size: 100)

    #expect(sidebar.avatarCacheKey == toolbar.avatarCacheKey)
    #expect(toolbar.avatarCacheKey == chatInfo.avatarCacheKey)
    #expect(chatInfo.avatarCacheKey == UserAvatarImageSource(user: user)?.cacheKey)
  }

  @Test("current remote photo wins over an existing stale local file")
  @MainActor
  func remotePhotoIsAuthoritative() throws {
    var user = User(id: 42, email: nil, firstName: "Avatar")
    user.profileFileUniqueId = "current-photo"
    user.profileCdnUrl = "https://cdn.inline.chat/current.jpg"
    let avatar = UserAvatar(
      userID: user.id,
      firstName: user.firstName,
      lastName: nil,
      email: nil,
      username: nil,
      stableAvatarIdentity: user.stableAvatarIdentity,
      remoteURL: user.getRemoteURL(),
      localURL: URL(fileURLWithPath: "/dev/null")
    )
    let source = try #require(avatar.imageSource)
    let preview = try #require(UserAvatarImageSource(user: user))

    #expect(source.url == user.getRemoteURL())
    #expect(preview.url == source.url)
    #expect(preview.cacheKey == source.cacheKey)
  }

  #if os(macOS)
  @Test("verified local originals keep the remote cache identity and work offline")
  func verifiedOriginalIsPreferred() throws {
    let local = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(User.remoteProfilePhotoCacheFilePrefix)\(UUID().uuidString).png"
    )
    try Data([1]).write(to: local)
    defer { try? FileManager.default.removeItem(at: local) }
    let remote = URL(string: "https://example.invalid/current.jpg")!
    let source = try #require(UserAvatarImageSource(
      userID: 42, identity: "unique:current", remoteURL: remote, localURL: local, scale: 2
    ))
    let uncachedSource = try #require(UserAvatarImageSource(
      userID: 42, identity: "unique:current", remoteURL: remote, localURL: nil, scale: 2
    ))
    #expect(source.url == local)
    #expect(source.cacheKey == uncachedSource.cacheKey)
  }

  @Test("full-size preview preserves the original after loading a small avatar from cache")
  @MainActor
  func previewRetainsOriginalResolution() async throws {
    var user = User(id: 42, email: nil, firstName: "Avatar")
    user.profileFileUniqueId = "current-photo"
    user.profileCdnUrl = "https://example.invalid/current.jpg"
    let source = try #require(UserAvatarImageSource(user: user))
    let cache = ImageCache(name: "avatar-original-test-\(UUID().uuidString)")
    let manager = KingfisherManager(downloader: .default, cache: cache)
    let original = NSImage(size: NSSize(width: 512, height: 512))
    original.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 512, height: 512).fill()
    original.unlockFocus()
    cache.store(original, forKey: source.cacheKey, toDisk: false)

    let thumbnail = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<(cacheTypeIsNone: Bool, data: Data?), any Error>) in
      manager.retrieveImage(
        with: KF.ImageResource(downloadURL: source.url, cacheKey: source.cacheKey),
        options: [.onlyFromCache, .processor(DownsamplingImageProcessor(size: CGSize(width: 22, height: 22)))],
        completionHandler: { result in
          switch result {
          case .success(let image):
            continuation.resume(returning: (image.cacheType == .none, image.data()))
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
      )
    }
    // Kingfisher reports .none when processing a cached original, even though the returned data is a thumbnail.
    #expect(thumbnail.cacheTypeIsNone)
    let thumbnailData = try #require(thumbnail.data)
    let thumbnailImage = try #require(NSBitmapImageRep(data: thumbnailData))
    #expect(thumbnailImage.pixelsWide == 22)

    let previewData = try await source.originalImageData(using: manager, onlyFromCache: true)
    let preview = try #require(NSBitmapImageRep(data: previewData))
    #expect(preview.pixelsWide >= 512)
    #expect(preview.pixelsHigh >= 512)
    #expect(try #require(preview.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)).redComponent > 0.9)
  }
  #endif

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
    #expect(avatar.imageSource?.url == sharedAvatarURL)
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

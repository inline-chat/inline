import Foundation
import InlineKit
import Kingfisher
import Logger
import SwiftUI

public struct UserAvatar: View, Equatable {
  public nonisolated static func == (lhs: UserAvatar, rhs: UserAvatar) -> Bool {
    lhs.userId == rhs.userId
      && lhs.firstName == rhs.firstName && lhs.lastName == rhs.lastName && lhs.email == rhs.email
      && lhs.username == rhs.username && lhs.size == rhs.size
      && lhs.ignoresSafeArea == rhs.ignoresSafeArea
      && lhs.backgroundOpacity == rhs.backgroundOpacity
      && lhs.cacheRemoteAvatar == rhs.cacheRemoteAvatar
      && Self.avatarIdentity(
        stableAvatarIdentity: lhs.stableAvatarIdentity,
        remoteUrl: lhs.remoteUrl,
        localUrl: lhs.localUrl,
        userId: lhs.userId
      ) == Self.avatarIdentity(
        stableAvatarIdentity: rhs.stableAvatarIdentity,
        remoteUrl: rhs.remoteUrl,
        localUrl: rhs.localUrl,
        userId: rhs.userId
      )
  }

  let firstName: String?
  let lastName: String?
  let email: String?
  let username: String?
  let size: CGFloat
  let ignoresSafeArea: Bool
  let userId: Int64
  let backgroundOpacity: Double
  let cacheRemoteAvatar: Bool

  var stableAvatarIdentity: String?
  var remoteUrl: URL?
  var localUrl: URL?

  let nameForInitials: String

  private static let profilePhotoSizeKind = "f"

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @State private var avatarLoadFailed = false
  @State private var startedRemoteCacheUrl: URL?

  public static func getNameForInitials(user: User) -> String {
    AvatarColorUtility.formatNameForHashing(
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email
    )
  }

  public init(
    user: User,
    size: CGFloat = 32,
    ignoresSafeArea: Bool = false,
    backgroundOpacity: Double = 1.0,
    cacheRemoteAvatar: Bool = true,
    localAvatarURL: URL? = nil
  ) {
    userId = user.id
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    remoteUrl = user.getRemoteURL()
    localUrl = Self.existingFileUrl(localAvatarURL) ?? Self.existingFileUrl(user.getLocalURL())
    stableAvatarIdentity = user.stableAvatarIdentity
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(
    userInfo: UserInfo,
    size: CGFloat = 32,
    ignoresSafeArea: Bool = false,
    backgroundOpacity: Double = 1.0,
    cacheRemoteAvatar: Bool = true
  ) {
    let user = userInfo.user
    userId = user.id
    remoteUrl = user.getRemoteURL() // ?? userInfo.profilePhoto?.first?.getRemoteURL()
    localUrl = Self.existingFileUrl(user.getLocalURL()) // ?? userInfo.profilePhoto?.first?.getLocalURL()
    stableAvatarIdentity = userInfo.stableAvatarIdentity
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(
    apiUser: ApiUser,
    size: CGFloat = 32,
    ignoresSafeArea: Bool = false,
    backgroundOpacity: Double = 1.0,
    cacheRemoteAvatar: Bool = true
  ) {
    userId = apiUser.id
    firstName = apiUser.firstName
    lastName = apiUser.lastName
    email = apiUser.email
    username = apiUser.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    nameForInitials = AvatarColorUtility.formatNameForHashing(
      firstName: apiUser.firstName,
      lastName: apiUser.lastName,
      email: apiUser.email
    )
  }

  @ViewBuilder
  public var placeholder: some View {
    Circle().fill(Color.gray.opacity(0.5)).frame(width: size, height: size).fixedSize()
  }

  @ViewBuilder
  public var initials: some View {
    InitialsCircle(
      name: nameForInitials,
      size: size,
      symbol: shouldShowPersonSymbol ? "person.fill" : nil,
      backgroundOpacity: backgroundOpacity
    )
    .equatable()
    .frame(width: size, height: size)
    .fixedSize()
  }

  private var shouldShowPersonSymbol: Bool {
    firstName == nil && lastName == nil && email == nil && username == nil
  }

  private var backgroundColor: Color {
    AvatarColorUtility.colorFor(name: nameForInitials)
      .adjustLuminosity(by: colorScheme == .dark ? -0.1 : 0)
  }

  private var backgroundGradient: LinearGradient {
    LinearGradient(
      colors: [
        backgroundColor.adjustLuminosity(by: 0.2),
        backgroundColor.adjustLuminosity(by: 0),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var avatarUrl: URL? {
    localUrl ?? remoteUrl
  }

  private var avatarCacheKey: String {
    let scaleKey = Int((renderScale * 100).rounded())
    return "user-avatar:\(Self.profilePhotoSizeKind):scale\(scaleKey):\(avatarIdentity)"
  }

  private var avatarIdentity: String {
    Self.avatarIdentity(
      stableAvatarIdentity: stableAvatarIdentity,
      remoteUrl: remoteUrl,
      localUrl: localUrl,
      userId: userId
    )
  }

  private nonisolated static func avatarIdentity(
    stableAvatarIdentity: String?,
    remoteUrl: URL?,
    localUrl: URL?,
    userId: Int64
  ) -> String {
    if let stableAvatarIdentity,
       localUrl != nil || stableAvatarIdentity.hasPrefix("local:") == false {
      return stableAvatarIdentity
    }

    return remoteUrl?.absoluteString
      ?? localUrl?.lastPathComponent
      ?? "user:\(userId)"
  }

  private var targetSize: CGSize {
    let side = max(size, 1)
    return CGSize(width: side, height: side)
  }

  private var renderScale: CGFloat {
    max(displayScale, 1)
  }

  @ViewBuilder
  public var avatar: some View {
    if let avatarUrl {
      KFImage.url(avatarUrl, cacheKey: avatarCacheKey)
        .setProcessor(DownsamplingImageProcessor(size: targetSize))
        .scaleFactor(renderScale)
        .cacheOriginalImage()
        .loadDiskFileSynchronously()
        .cancelOnDisappear(true)
        .placeholder {
          if avatarLoadFailed {
            initials
          } else {
            placeholder
          }
        }
        .onSuccess { result in
          avatarLoadFailed = false
          let downloadedData = result.cacheType == .none ? result.data() : nil
          cacheRemoteAvatarIfNeeded(sourceUrl: avatarUrl, downloadedData: downloadedData)
        }
        .onFailure { _ in
          avatarLoadFailed = true
        }
        .resizable()
        // For non-square profile photos.
        .aspectRatio(contentMode: .fill)
        .frame(width: size, height: size)
        .background(backgroundGradient)
        .clipShape(Circle())
        .fixedSize()
    } else {
      initials
    }
  }

  public var body: some View {
    if ignoresSafeArea {
      avatar
        // Important so the toolbar safe area doesn't affect it
        .ignoresSafeArea(.all)
    } else {
      avatar
    }
  }

  private func cacheRemoteAvatarIfNeeded(sourceUrl: URL, downloadedData: Data?) {
    guard cacheRemoteAvatar else { return }
    guard sourceUrl.isFileURL == false else { return }
    guard localUrl == nil else { return }
    guard startedRemoteCacheUrl != sourceUrl else { return }

    startedRemoteCacheUrl = sourceUrl

    Task.detached(priority: .utility) { [userId, sourceUrl, downloadedData] in
      do {
        let data: Data

        if let downloadedData, downloadedData.isEmpty == false {
          data = downloadedData
        } else {
          let (remoteData, response) = try await URLSession.shared.data(from: sourceUrl)
          if let httpResponse = response as? HTTPURLResponse,
             (200 ... 299).contains(httpResponse.statusCode) == false {
            return
          }
          data = remoteData
        }

        guard data.isEmpty == false else { return }
        try await User.cacheImageData(userId: userId, data: data)
      } catch {
        Log.shared.error("Failed to cache image", error: error)
      }
    }
  }

  private static func existingFileUrl(_ url: URL?) -> URL? {
    guard let url else { return nil }
    guard url.isFileURL else { return url }
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
}

#Preview("UserAvatar") {
  HStack(spacing: 16) {
    UserAvatar(
      user: User(id: 1, email: "ada@example.com", firstName: "Ada", lastName: "Lovelace"),
      size: 64
    )

    UserAvatar(
      user: User(id: 2, email: "grace@example.com", firstName: "Grace", lastName: "Hopper"),
      size: 48
    )

    UserAvatar(
      user: User(id: 3, email: nil, firstName: nil),
      size: 32
    )
  }
  .padding(24)
}

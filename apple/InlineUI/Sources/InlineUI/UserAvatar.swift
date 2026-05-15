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
      && lhs.stableAvatarIdentity == rhs.stableAvatarIdentity
  }

  let firstName: String?
  let lastName: String?
  let email: String?
  let username: String?
  let size: CGFloat
  let ignoresSafeArea: Bool
  let userId: Int64
  let backgroundOpacity: Double

  var stableAvatarIdentity: String? = nil
  var remoteUrl: URL? = nil
  var localUrl: URL? = nil

  let nameForInitials: String

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @State private var avatarLoadFailed = false

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
    backgroundOpacity: Double = 1.0
  ) {
    userId = user.id
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    remoteUrl = user.getRemoteURL()
    localUrl = Self.existingFileUrl(user.getLocalURL())
    stableAvatarIdentity = user.stableAvatarIdentity
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(
    userInfo: UserInfo,
    size: CGFloat = 32,
    ignoresSafeArea: Bool = false,
    backgroundOpacity: Double = 1.0
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
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(
    apiUser: ApiUser,
    size: CGFloat = 32,
    ignoresSafeArea: Bool = false,
    backgroundOpacity: Double = 1.0
  ) {
    userId = apiUser.id
    firstName = apiUser.firstName
    lastName = apiUser.lastName
    email = apiUser.email
    username = apiUser.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
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
    let identity = stableAvatarIdentity
      ?? remoteUrl?.absoluteString
      ?? localUrl?.absoluteString
      ?? "user:\(userId)"

    return "user-avatar:\(identity)"
  }

  private var targetSize: CGSize {
    let side = max(size, 1)
    return CGSize(width: side, height: side)
  }

  @ViewBuilder
  public var avatar: some View {
    if let avatarUrl {
      KFImage.url(avatarUrl, cacheKey: avatarCacheKey)
        .setProcessor(DownsamplingImageProcessor(size: targetSize))
        .scaleFactor(displayScale)
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
          cacheRemoteAvatarIfNeeded(result, sourceUrl: avatarUrl)
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

  private func cacheRemoteAvatarIfNeeded(_ result: RetrieveImageResult, sourceUrl: URL) {
    guard sourceUrl.isFileURL == false else { return }
    guard localUrl == nil else { return }
    guard result.cacheType == .none else { return }
    guard let data = result.data(), data.isEmpty == false else { return }

    Task.detached(priority: .utility) { [userId, data] in
      do {
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

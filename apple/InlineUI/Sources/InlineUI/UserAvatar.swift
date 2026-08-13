import Foundation
import InlineAvatarCore
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
      && lhs.hasConfiguredPhoto == rhs.hasConfiguredPhoto
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
  let hasConfiguredPhoto: Bool

  var stableAvatarIdentity: String?
  var remoteUrl: URL?
  var localUrl: URL?

  let nameForInitials: String
  let showsPersonSymbol: Bool

  private static let profilePhotoSizeKind = "f"

  @Environment(\.displayScale) private var displayScale
  @State private var startedRemoteCacheUrl: URL?

  public nonisolated static func getNameForInitials(user: User) -> String {
    avatarPresentation(
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email,
      username: user.username,
      stableIdentifier: "user:\(user.id)"
    ).seed
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
    hasConfiguredPhoto = stableAvatarIdentity != nil || remoteUrl != nil || localUrl != nil
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    let presentation = Self.avatarPresentation(
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email,
      username: user.username,
      stableIdentifier: "user:\(user.id)"
    )
    nameForInitials = presentation.seed
    showsPersonSymbol = presentation.showsPersonSymbol
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
    hasConfiguredPhoto = stableAvatarIdentity != nil || remoteUrl != nil || localUrl != nil
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    let presentation = Self.avatarPresentation(
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email,
      username: user.username,
      stableIdentifier: "user:\(user.id)"
    )
    nameForInitials = presentation.seed
    showsPersonSymbol = presentation.showsPersonSymbol
  }

  /// Creates an avatar from values that were prepared off the main actor.
  /// Callers are responsible for validating `localURL` before constructing the view.
  public init(
    userID: Int64,
    firstName: String?,
    lastName: String?,
    email: String?,
    username: String?,
    stableAvatarIdentity: String?,
    remoteURL: URL?,
    localURL: URL?,
    size: CGFloat = 32,
    ignoresSafeArea: Bool = false,
    backgroundOpacity: Double = 1.0,
    cacheRemoteAvatar: Bool = true
  ) {
    userId = userID
    self.firstName = firstName
    self.lastName = lastName
    self.email = email
    self.username = username
    self.stableAvatarIdentity = stableAvatarIdentity
    remoteUrl = remoteURL
    localUrl = localURL
    hasConfiguredPhoto = stableAvatarIdentity != nil || remoteURL != nil || localURL != nil
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    let presentation = Self.avatarPresentation(
      firstName: firstName,
      lastName: lastName,
      email: email,
      username: username,
      stableIdentifier: stableAvatarIdentity ?? "user:\(userID)"
    )
    nameForInitials = presentation.seed
    showsPersonSymbol = presentation.showsPersonSymbol
  }

  public init(
    apiUser: ApiUser,
    size: CGFloat = 32,
    ignoresSafeArea: Bool = false,
    backgroundOpacity: Double = 1.0,
    cacheRemoteAvatar: Bool = true
  ) {
    let profilePhoto = apiUser.photo?.first
    userId = apiUser.id
    firstName = apiUser.firstName
    lastName = apiUser.lastName
    email = apiUser.email
    username = apiUser.username
    stableAvatarIdentity = profilePhoto.map { "unique:\($0.fileUniqueId)" }
    remoteUrl = profilePhoto.flatMap { URL(string: $0.temporaryUrl) }
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    hasConfiguredPhoto = profilePhoto != nil
    let presentation = Self.avatarPresentation(
      firstName: apiUser.firstName,
      lastName: apiUser.lastName,
      email: apiUser.email,
      username: apiUser.username,
      stableIdentifier: "user:\(apiUser.id)"
    )
    nameForInitials = presentation.seed
    showsPersonSymbol = presentation.showsPersonSymbol
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
      symbol: showsPersonSymbol ? "person.fill" : nil,
      backgroundOpacity: backgroundOpacity
    )
    .equatable()
    .frame(width: size, height: size)
    .fixedSize()
  }

  private var backgroundGradient: LinearGradient {
    let style = InlineAvatarStyle.resolved(seed: nameForInitials)
    return LinearGradient(
      gradient: Gradient(stops: style.gradientStops.map {
        .init(color: Color(avatarColor: $0.color), location: $0.location)
      }),
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private nonisolated static func avatarPresentation(
    firstName: String?,
    lastName: String?,
    email: String?,
    username: String?,
    stableIdentifier: String
  ) -> InlineUserAvatarPresentation {
    InlineAvatarPresentation.user(identity: .init(
      firstName: firstName,
      lastName: lastName,
      displayName: nil,
      email: email,
      username: username,
      stableIdentifier: stableIdentifier
    ))
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
          placeholder
        }
        .onSuccess { result in
          let downloadedData = result.cacheType == .none ? result.data() : nil
          cacheRemoteAvatarIfNeeded(sourceUrl: avatarUrl, downloadedData: downloadedData)
        }
        .resizable()
        // For non-square profile photos.
        .aspectRatio(contentMode: .fill)
        .frame(width: size, height: size)
        .background(backgroundGradient)
        .clipShape(Circle())
        .fixedSize()
    } else if hasConfiguredPhoto {
      placeholder
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

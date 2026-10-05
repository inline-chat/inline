import Auth
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
      && lhs.localUrl == rhs.localUrl
      && lhs.remoteUrl == rhs.remoteUrl
      && lhs.prefersExplicitLocalSource == rhs.prefersExplicitLocalSource
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
  private var prefersExplicitLocalSource = false

  let nameForInitials: String
  let showsPersonSymbol: Bool

  @Environment(\.displayScale) private var displayScale

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
    localUrl = localAvatarURL ?? user.getLocalURL()
    prefersExplicitLocalSource = localAvatarURL != nil
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
    localUrl = user.getLocalURL() // ?? userInfo.profilePhoto?.first?.getLocalURL()
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
  /// Local file availability is checked by the image loader, outside view construction.
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
    userId = apiUser.id
    firstName = apiUser.firstName
    lastName = apiUser.lastName
    email = apiUser.email
    username = apiUser.username
    stableAvatarIdentity = apiUser.avatarFileUniqueID.map { "unique:\($0)" }
    remoteUrl = apiUser.avatarURL
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    self.backgroundOpacity = backgroundOpacity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    hasConfiguredPhoto = apiUser.hasConfiguredProfilePhoto
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

  var imageSource: UserAvatarImageSource? {
    UserAvatarImageSource(
      userID: userId,
      identity: stableAvatarIdentity,
      remoteURL: remoteUrl,
      localURL: localUrl,
      scale: renderScale,
      prefersExplicitLocalSource: prefersExplicitLocalSource
    )
  }

  var avatarCacheKey: String? { imageSource?.cacheKey }

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

  private var renderScale: CGFloat {
    max(displayScale, 1)
  }

  @ViewBuilder
  public var avatar: some View {
    if let imageSource {
      UserAvatarPhoto(source: imageSource, size: size, scale: renderScale,
                      userID: userId, photoIdentity: stableAvatarIdentity,
                      cacheRemoteAvatar: cacheRemoteAvatar)
        .id(UserAvatarPhotoIdentity(source: imageSource, size: size, scale: renderScale))
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

}

/// A new processing configuration needs a new loader, even when the original bytes are unchanged.
struct UserAvatarPhotoIdentity: Hashable {
  let source: UserAvatarImageSource
  let size: CGFloat
  let scale: CGFloat
}

/// Source-scoped lifetime prevents delayed retries and cache writes from a recycled avatar.
struct UserAvatarPhoto: View {
  let source: UserAvatarImageSource
  let size: CGFloat
  let scale: CGFloat
  let userID: Int64
  let photoIdentity: String?
  let cacheRemoteAvatar: Bool
  @State private var loader: AvatarImageLoader
  @State private var startedCache = false

  init(source: UserAvatarImageSource, size: CGFloat, scale: CGFloat, userID: Int64,
       photoIdentity: String?, cacheRemoteAvatar: Bool, loader: AvatarImageLoader = AvatarImageLoader()) {
    self.source = source
    self.size = size
    self.scale = scale
    self.userID = userID
    self.photoIdentity = photoIdentity
    self.cacheRemoteAvatar = cacheRemoteAvatar
    _loader = State(initialValue: loader)
  }

  var body: some View {
    Group {
      if let image = loader.image {
        #if os(macOS)
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        #else
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        #endif
      } else {
        Circle().fill(Color.gray.opacity(0.5)).frame(width: size, height: size)
      }
    }
    .onAppear {
      loader.start(source: source, size: size, scale: scale) { loadedURL in cacheOriginalIfNeeded(loadedURL: loadedURL) }
    }
    .onDisappear { loader.cancel() }
  }

  private func cacheOriginalIfNeeded(loadedURL: URL) {
    guard cacheRemoteAvatar, !loadedURL.isFileURL, !startedCache,
          let account = loader.currentAccount else { return }
    startedCache = true
    Task { [source, userID, photoIdentity] in
      do {
        let data = try await source.originalImageData()
        guard loader.isCurrent else { return }
        try Auth.shared.handle.validateAccountMutation(account)
        try await User.cacheImageData(
          userId: userID, data: data, expectedSourceURL: loadedURL,
          expectedAvatarIdentity: photoIdentity, accountToken: account
        )
      } catch {
        // Stale-source/account fencing is expected when a photo is replaced during retrieval.
        guard loader.isCurrent else { return }
        Log.shared.error("Failed to cache avatar original", error: AvatarImageFailure.cache)
      }
    }
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

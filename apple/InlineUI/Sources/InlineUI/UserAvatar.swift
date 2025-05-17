import GRDB
import InlineKit
import Logger
import Nuke
import NukeUI
import SwiftUI

public struct UserAvatar: View, Equatable {
  public nonisolated static func == (lhs: UserAvatar, rhs: UserAvatar) -> Bool {
    lhs.firstName == rhs.firstName && lhs.lastName == rhs.lastName && lhs.email == rhs.email
      && lhs.username == rhs.username && lhs.size == rhs.size
      && lhs.ignoresSafeArea == rhs.ignoresSafeArea
      // FIXME: This causes flicker because every time we fetch there is a new URL
      && lhs.remoteUrl == rhs.remoteUrl
      && lhs.fileId == rhs.fileId && lhs.localUrl == rhs.localUrl
  }

  let firstName: String?
  let lastName: String?
  let email: String?
  let username: String?
  let size: CGFloat
  let ignoresSafeArea: Bool
  let userId: Int64

  var file: File? = nil
  var fileId: String? = nil
  var remoteUrl: URL? = nil
  var localUrl: URL? = nil

  let nameForInitials: String

  public static func getNameForInitials(user: User) -> String {
    AvatarColorUtility.formatNameForHashing(
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email
    )
  }

  public init(user: User, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    userId = user.id
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    remoteUrl = user.getRemoteURL()
    localUrl = user.getLocalURL()
    self.ignoresSafeArea = ignoresSafeArea
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(userInfo: UserInfo, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    let user = userInfo.user
    userId = user.id
    file = userInfo.profilePhoto?.first
    fileId = userInfo.profilePhoto?.first?.id
    remoteUrl = user.getRemoteURL()// ?? userInfo.profilePhoto?.first?.getRemoteURL()
    localUrl = user.getLocalURL() // ?? userInfo.profilePhoto?.first?.getLocalURL()
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(apiUser: ApiUser, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    userId = apiUser.id
    firstName = apiUser.firstName
    lastName = apiUser.lastName
    email = apiUser.email
    username = apiUser.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
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
      size: size
    )
    .equatable()
    .frame(width: size, height: size)
    .fixedSize()
  }

  @Environment(\.colorScheme) private var colorScheme

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

  @ViewBuilder
  public var avatar: some View {
    if remoteUrl != nil || localUrl != nil {
      LazyImage(
        url: localUrl ?? remoteUrl,
        content: { state in

          if state.isLoading {
            placeholder
          } else if state.error != nil {
            initials
          } else {
            state.image?
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: size, height: size)
              .background(backgroundGradient)
              .clipShape(Circle())
              .fixedSize()
              .task {
                // don't re-save if already
                guard localUrl == nil else { return }
                guard let image = try? state.result?.get().image else { return }

                Task.detached {
                  do {
                    try await User.cacheImage(userId: userId, image: image)
                  } catch {
                    Log.shared.error("Failed to cache image", error: error)
                  }
                }
              }
          }
        }
      )
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

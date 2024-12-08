import InlineKit
import SwiftUI

public struct UserAvatar: View, Equatable {
  public nonisolated static func == (lhs: UserAvatar, rhs: UserAvatar) -> Bool {
    lhs.firstName == rhs.firstName &&
      lhs.lastName == rhs.lastName &&
      lhs.email == rhs.email &&
      lhs.username == rhs.username &&
      lhs.size == rhs.size
  }

  let firstName: String?
  let lastName: String?
  let email: String?
  let username: String?
  let size: CGFloat
  let ignoresSafeArea: Bool

  public init(user: User, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    self.firstName = user.firstName
    self.lastName = user.lastName
    self.email = user.email
    self.username = user.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
  }

  public init(apiUser: ApiUser, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    self.firstName = apiUser.firstName
    self.lastName = apiUser.lastName
    self.email = apiUser.email
    self.username = apiUser.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
  }

  @ViewBuilder
  public var avatar: some View {
    InitialsCircle(
      firstName: firstName ?? email?.components(separatedBy: "@").first ?? "User",
      lastName: lastName,
      size: size
    )
    .frame(width: size, height: size)
  }

  public var body: some View {
    if ignoresSafeArea {
      avatar
        // Important so the toolbar safe area doesn't affect it
        .ignoresSafeArea()
    } else {
      avatar
    }
  }
}

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

  let nameForInitials: String

  public init(user: User, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(apiUser: ApiUser, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    firstName = apiUser.firstName
    lastName = apiUser.lastName
    email = apiUser.email
    username = apiUser.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    nameForInitials = Self.getNameForInitials(user: apiUser)
  }

  // This must match below
  static func getNameForInitials(user: User) -> String {
    let firstName = user.firstName ?? user.email?.components(separatedBy: "@").first ?? "User"
    let lastName = user.lastName
    let name = "\(firstName) \(lastName ?? "")"
    return name
  }

  static func getNameForInitials(user: ApiUser) -> String {
    let firstName = user.firstName ?? user.email?.components(separatedBy: "@").first ?? "User"
    let lastName = user.lastName
    let name = "\(firstName) \(lastName ?? "")"
    return name
  }

  @ViewBuilder
  public var avatar: some View {
    InitialsCircle(
      name: nameForInitials,
      size: size
    )
    .frame(width: size, height: size)
    .fixedSize()
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

import InlineKit
import SwiftUI

public struct UserAvatar: View {
  let firstName: String?
  let lastName: String?
  let email: String?
  let username: String?
  let size: CGFloat

  public init(user: User, size: CGFloat = 32) {
    self.firstName = user.firstName
    self.lastName = user.lastName
    self.email = user.email
    self.username = user.username
    self.size = size
  }
  
  public init(apiUser:  ApiUser, size: CGFloat = 32) {
    self.firstName = apiUser.firstName
    self.lastName = apiUser.lastName
    self.email = apiUser.email
    self.username = apiUser.username
    self.size = size
  }

  public var body: some View {
    ZStack {
      InitialsCircle(
        firstName: firstName ?? email?.components(separatedBy: "@").first ?? "User",
        lastName: lastName,
        size: size
      )
    }
  }
}


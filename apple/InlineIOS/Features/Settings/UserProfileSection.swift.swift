import InlineKit
import InlineUI
import SwiftUI

struct UserProfileSection: View {
  let currentUser: UserInfo?

  var body: some View {
    Section(header: Text("Account")) {
      if let user = currentUser {
        ProfileRow(userInfo: user)
      } else {
        Button("Set up profile") {
          // TODO: Add profile setup
        }
      }
    }
  }
}

struct ProfileRow: View {
  let userInfo: UserInfo
  var user: User {
    userInfo.user
  }

  var isChatInfo: Bool = false

  private var fullName: String {
    [user.firstName, user.lastName]
      .compactMap(\.self)
      .joined(separator: " ")
  }

  init(userInfo: UserInfo, isChatInfo: Bool = false) {
    self.userInfo = userInfo
    self.isChatInfo = isChatInfo
  }

  var body: some View {
    HStack {
      UserAvatar(userInfo: userInfo, size: 42)
        .padding(.trailing, 6)

      VStack(alignment: .leading, spacing: 0) {
        Text(fullName)
          .font(.body)
          .fontWeight(.medium)
        if !isChatInfo {
          Text(user.email ?? "")
            .font(.callout)
            .foregroundColor(.secondary)
        } else {
          Text("@\(user.username ?? "")")
            .font(.callout)
            .foregroundColor(.secondary)
        }
      }
    }
  }
}

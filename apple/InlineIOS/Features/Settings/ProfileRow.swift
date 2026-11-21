import InlineKit
import InlineUI
import SwiftUI

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
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(fullName)
            .font(.body)
            .fontWeight(.medium)

          if !isChatInfo {
            AccountPlanTag(user: user, size: 15)
          }
        }

        if !isChatInfo {
          Text(user.email ?? "")
            .font(.callout)

        } else {
          Text("@\(user.username ?? "")")
            .font(.callout)

        }
      }
    }
  }
}

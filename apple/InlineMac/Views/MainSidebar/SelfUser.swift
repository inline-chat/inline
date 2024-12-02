import InlineKit
import InlineUI
import SwiftUI

struct SelfUser: View {
  @EnvironmentObject var rootData: RootData
  @Environment(\.appearsActive) var appearsActive

  var currentUser: User {
    rootData.currentUser ?? defaultUser()
  }

  var body: some View {
    HStack(spacing: 0) {
      UserAvatar(user: currentUser, size: Theme.sidebarIconSize)
        .padding(.trailing, Theme.sidebarIconSpacing)

      Text(currentUser.firstName ?? "You")
        .font(Theme.sidebarTopItemFont)
        .foregroundStyle(
          appearsActive ? .primary : .tertiary
        )
    }
    .frame(height: Theme.sidebarTopItemHeight)
  }

  func defaultUser() -> User {
    User(email: nil, firstName: "You")
  }
}

#Preview {
  SelfUser()
    .frame(width: 200)
    .previewsEnvironmentForMac(.populated)
}

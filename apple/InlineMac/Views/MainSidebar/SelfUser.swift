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

      ConnectionStateProvider { connection in
        VStack(alignment: .leading, spacing: 0) {
          Text(currentUser.firstName ?? "You")
            .font(Theme.sidebarTopItemFont)
            .foregroundStyle(
              appearsActive ? .primary : .tertiary
            ).padding(.bottom, 0)

          if connection.shouldShow {
            Text(connection.humanReadable)
              .lineLimit(1)
              .font(.caption)
              .foregroundStyle(.secondary)
              .contentTransition(.identity)
              .padding(.top, -2)
          }
        }
        
        .animation(.smoothSnappy, value: connection.state)
        .animation(.smoothSnappy, value: connection.shouldShow)
      }
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

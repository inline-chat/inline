import InlineKit
import InlineUI
import SwiftUI

struct SelfUser: View {
  @EnvironmentObject var rootData: RootData
  @Environment(\.appearsActive) var appearsActive

  var currentUser: User {
    rootData.currentUser ?? defaultUser()
  }

  var visibleName: String {
    currentUser.firstName ??
      currentUser.lastName ??
      (currentUser.username != nil ? "@\(currentUser.username ?? "")" : nil) ??
      currentUser.email ??
      "Loading..."
  }

  var body: some View {
    HStack(spacing: 0) {
      UserAvatar(user: currentUser, size: Theme.sidebarIconSize)
        .padding(.trailing, Theme.sidebarIconSpacing)

      ConnectionStateProvider { connection in
        // TODO: Extract to a separate view
        VStack(alignment: .leading, spacing: 0) {
          // <name>
          Text(visibleName)
            .font(Theme.sidebarTopItemFont)
            +
            Text(" (you)")
            .font(Theme.sidebarTopItemFont)
            .foregroundColor(Color.secondary.opacity(0.7))

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
    .frame(maxWidth: .infinity, alignment: .leading)
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

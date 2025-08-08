import InlineKit
import InlineUI
import SwiftUI

struct SelfUser: View {
  @EnvironmentObject var rootData: RootData
  @EnvironmentObject var nav: NavigationModel
  @Environment(\.appearsActive) var appearsActive

  var currentUser: User {
    rootData.currentUser ?? defaultUser()
  }

  var currentUserInfo: UserInfo {
    rootData.currentUserInfo ?? defaultUserInfo()
  }

  var visibleName: String {
    currentUser.firstName ??
      currentUser.lastName ??
      (currentUser.username != nil ? "@\(currentUser.username ?? "")" : nil) ??
      currentUser.email ??
      "Loading..."
  }

  var body: some View {
    // Button(action: openSelfProfile) {
    HStack(spacing: 0) {
      UserAvatar(userInfo: currentUserInfo, size: Theme.sidebarIconSize, ignoresSafeArea: false)
        .padding(.trailing, Theme.sidebarIconSpacing)
        .scaleEffect(1.0)

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
    // }
    // .buttonStyle(.plain)
    .frame(height: Theme.sidebarTopItemHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .id("user-avatar-in-sidebar")
    .onTapGesture {
      openSelfProfile()
    }
  }

  func defaultUser() -> User {
    User(email: nil, firstName: "You")
  }

  func defaultUserInfo() -> UserInfo {
    UserInfo(user: User(email: nil, firstName: "You"))
  }

  func openSelfProfile() {
    guard let userInfo = rootData.currentUserInfo else { return }
    nav.navigate(to: .profile(userInfo: userInfo))
  }
}

#Preview {
  SelfUser()
    .frame(width: 200)
    .previewsEnvironmentForMac(.populated)
}

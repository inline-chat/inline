import InlineKit
import InlineUI
import SwiftUI

struct HomeToolbarContent: ToolbarContent {
  let userInfo: UserInfo?

  var user: User? {
    userInfo?.user
  }

  @EnvironmentObject private var ws: WebSocketManager
  @EnvironmentObject private var nav: Navigation

  init(
    userInfo: UserInfo?
  ) {
    self.userInfo = userInfo
  }

  var body: some ToolbarContent {
    ToolbarItem(id: "UserAvatar", placement: .topBarLeading) {
      userAvatarView
    }

    ToolbarItemGroup(placement: .topBarTrailing) {
      createSpaceButton
      settingsButton
    }
  }

  private var userAvatarView: some View {
    HStack(spacing: 8) {
//        if let userInfo {
//          UserAvatar(userInfo: userInfo, size: 26)
//        } else if let user {
//          UserAvatar(user: user, size: 26)
//        }
      if let user {
        UserAvatar(user: user, size: 26)
      }

      VStack(alignment: .leading, spacing: 0) {
        userNameView
        if ws.connectionState == .connecting {
          Text("connecting...")
            .font(.caption)
            .foregroundStyle(.secondary)
            .transition(.opacity)
            .animation(.easeInOut, value: ws.connectionState)
        }
      }
    }

    .onTapGesture {
      if let userInfo {
        nav.push(.profile(userInfo: userInfo))
      }
    }
  }

  private var userNameView: some View {
    HStack(alignment: .center, spacing: 4) {
      Text(user?.firstName ?? user?.lastName ?? user?.email ?? "User")
        .font(.title3)
        .fontWeight(.semibold)

      Text("(you)")
        .font(.body)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
    }
  }

//  private var trailingButtons: some View {
//    HStack(spacing: 2) {
//      createSpaceButton
//      settingsButton
//    }
//  }

  private var createSpaceButton: some View {
    Button {
      nav.push(.createSpace)
    } label: {
      Image(systemName: "plus")
        .tint(Color.secondary)
        .frame(width: 38, height: 38)
        .contentShape(Rectangle())
    }
  }

  private var settingsButton: some View {
    Button {
      nav.push(.settings)
    } label: {
      Image(systemName: "gearshape")
        .tint(Color.secondary)
        .frame(width: 38, height: 38)
        .contentShape(Rectangle())
    }
  }
}

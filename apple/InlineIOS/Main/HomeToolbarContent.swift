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
    Group {
      ToolbarItem(id: "UserAvatar", placement: .topBarLeading) {
        userAvatarView
      }

      ToolbarItem(id: "status", placement: .principal) {
        ConnectionStateIndicator(state: ws.connectionState)
      }

      ToolbarItem(id: "MainToolbarTrailing", placement: .topBarTrailing) {
        trailingButtons
      }
    }
  }

  private var userAvatarView: some View {
    HStack {
      if let userInfo {
        UserAvatar(userInfo: userInfo, size: 26)

      } else if let user {
        UserAvatar(user: user, size: 26)
      }

      userNameView
    }
    .padding(.horizontal, 18)
    .onTapGesture {
      if let userInfo = userInfo {
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
    .scaledToFill()
  }

  private var trailingButtons: some View {
    HStack(spacing: 2) {
      createSpaceButton
      settingsButton
    }
  }

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

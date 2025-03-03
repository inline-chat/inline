import InlineKit
import InlineUI
import RealtimeAPI
import SwiftUI

struct HomeToolbarContent: ToolbarContent {
  let userInfo: UserInfo?

  var user: User? {
    userInfo?.user
  }

  @EnvironmentObject private var nav: Navigation
  @Environment(\.realtime) var realtime

  @State var shouldShow = false
  @State var apiState: RealtimeAPIState = .connecting

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

  @ViewBuilder
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
        if shouldShow {
          Text(getStatusText(apiState))
            .font(.caption)
            .foregroundStyle(.secondary)
            .transition(.opacity)
        }
      }
    }
    .onTapGesture {
      if let userInfo {
        nav.push(.profile(userInfo: userInfo))
      }
    }
    .onAppear {
      apiState = realtime.apiState

      if apiState != .connected {
        shouldShow = true
      }
    }
    .onReceive(realtime.apiStatePublisher, perform: { nextApiState in
      apiState = nextApiState
      print("shouldShow1  \(shouldShow) - \(apiState) - \(nextApiState)")
      if nextApiState == .connected {
        Task { @MainActor in
          try await Task.sleep(for: .seconds(1))
          if nextApiState == .connected {
            // second check
            shouldShow = false
            print("shouldShow2  \(shouldShow) - \(apiState) - \(nextApiState)")
          }
        }
      } else {
        shouldShow = true
      }
    })
  }

  @ViewBuilder
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

  @ViewBuilder
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

  @ViewBuilder
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

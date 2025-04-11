import InlineKit
import InlineUI
import SwiftUI

struct UserItem: View {
  @EnvironmentObject var nav: NavigationModel
  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool
  @Environment(\.appearsActive) var appearsActive

  var userInfo: UserInfo
  var dialog: Dialog?
  var chat: Chat?
  var action: (() -> Void)?
  var commandPress: (() -> Void)?
  var selected: Bool = false
  var rendersSavedMsg: Bool = false

  var user: User {
    userInfo.user
  }

  var profilePhoto: File? {
    userInfo.profilePhoto?.first
  }

  var isCurrentUser: Bool {
    user.isCurrentUser()
  }

  var isSavedMsg: Bool {
    isCurrentUser && rendersSavedMsg
  }

  var name: String {
    user.firstName ?? user.username ?? ""
  }

  var unreadCount: Int {
    dialog?.unreadCount ?? 0
  }

  var hasUnread: Bool {
    unreadCount > 0
  }

  var body: some View {
    let text = Text(isSavedMsg ? "Saved Messages" : name)
      .lineLimit(1)

    let view = Button {
      action?()
    } label: {
      HStack(spacing: 0) {
        if isSavedMsg {
          InitialsCircle(name: name, size: Theme.sidebarIconSize, symbol: "bookmark.fill")
            .padding(.trailing, Theme.sidebarIconSpacing)
        } else {
          UserAvatar(userInfo: userInfo, size: Theme.sidebarIconSize)
            .padding(.trailing, Theme.sidebarIconSpacing)
        }

        HStack(spacing: 3) {
          text
            .fixedSize(horizontal: false, vertical: true)

          // Should we show this in home? probably not, but in space we need it
          if isCurrentUser, !isSavedMsg {
            Text("(You)").lineLimit(1).foregroundStyle(
              appearsActive ? .tertiary : .quaternary
            )
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        .font(Theme.sidebarItemFont)

//        .transaction { transaction in
//          transaction.disablesAnimations = true
//        }

        Spacer()
      }
    }
    .buttonStyle(UserItemButtonStyle(
      isHovered: $isHovered,
      isFocused: isFocused,
      selected: selected,
      appearsActive: appearsActive
    ))
    // unread dot
    .overlay(alignment: .leading) {
      AnimatedUnreadDot(isVisible: hasUnread)
    }
    .focused($isFocused)
    .padding(.horizontal, -Theme.sidebarItemInnerSpacing)

    // Menu
    .contextMenu(menuItems: {
      // Only creators can delete space for now
      if hasUnread {
        Button("Read All") {
          if let peerId = dialog?.peerId, let chatId = chat?.id {
            UnreadManager.shared.readAll(peerId, chatId: chatId)
          }
        }
      } else {
        Button("Mark as Unread") {
          // TODO:
        }.disabled(true)
      }
    })

    // Command-click handler
    .simultaneousGesture(
      TapGesture(count: 1)
        .modifiers(.command)
        .onEnded {
          commandPress?()
        }
    )

    if #available(macOS 14.0, *) {
      view.focusEffectDisabled().fixedSize(horizontal: false, vertical: true)
    } else {
      view.fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct UnreadDot: View {
  @Environment(\.appearsActive) var appearsActive
  var body: some View {
    Circle()
      // muted gray makes app window less distractive if user does not want to pay attention
      .fill(
        appearsActive ?
          Color.blue :
          Color.gray.opacity(0.5)
      )
      .frame(width: 4, height: 4)
  }
}

struct AnimatedUnreadDot: View {
  let isVisible: Bool

  var body: some View {
    UnreadDot()
      .padding(.leading, 4.0)
      .opacity(isVisible ? 1 : 0)
      .scaleEffect(isVisible ? 1 : 0)
      // a slight delay to avoid quick flicker .delay(0.1)
      .animation(.easeOut(duration: 0.15), value: isVisible)
  }
}

struct UserItemButtonStyle: ButtonStyle {
  @Binding var isHovered: Bool
  let isFocused: Bool
  let selected: Bool
  let appearsActive: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(height: Theme.sidebarItemHeight)
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .padding(.trailing, Theme.sidebarItemInnerSpacing)
      .padding(.leading, Theme.sidebarItemInnerSpacing) // gutter makes place for unread
      .background {
        Group {
          RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
            .fill(backgroundColor(configuration))
        }
//        .transaction { transaction in
//          if selected {
//            transaction.disablesAnimations = true
//            transaction.animation = .none
//          }
//        }
      }
      .onHover { isHovered = $0 }
      // Optional: Add subtle scale effect when pressed
//      .scaleEffect(!selected && configuration.isPressed ? 0.98 : 1.0)
      .animation(.easeOut(duration: 0.04), value: isHovered)
      .padding(.vertical, Theme.sidebarItemSpacing)
  }

  private func backgroundColor(_ configuration: Configuration) -> Color {
    if selected {
      .primary.opacity(0.1)
    } else if configuration.isPressed {
      .primary.opacity(0.1)
    } else if isFocused {
      .primary.opacity(0.08)
    } else if isHovered {
      .primary.opacity(0.04)
    } else {
      .clear
    }
  }
}

// #Preview {
//  VStack(spacing: 0) {
//    UserItem(user: User.preview)
//    UserItem(
//      user: User.preview,
//      action: {
//        print("Custom action")
//      }
//    )
//  }
//  .frame(width: 200)
//  .previewsEnvironmentForMac(.populated)
// }

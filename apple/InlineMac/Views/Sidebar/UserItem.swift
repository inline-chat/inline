import InlineKit
import InlineUI
import SwiftUI

struct UserItem: View {
  @EnvironmentObject var nav: NavigationModel
  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool
  @Environment(\.appearsActive) var appearsActive

  var user: User
  var action: (() -> Void)?
  var commandPress: (() -> Void)?
  var selected: Bool = false
  var rendersSavedMsg: Bool = false
  
  var isCurrentUser: Bool {
    user.isCurrentUser()
  }
  
  var isSavedMsg: Bool {
    isCurrentUser && rendersSavedMsg
  }

  var name: String {
    user.firstName ?? user.username ?? ""
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
          UserAvatar(user: user, size: Theme.sidebarIconSize)
            .padding(.trailing, Theme.sidebarIconSpacing)
        }

        HStack(spacing: 3) {
          text

          // Should we show this in home? probably not, but in space we need it
          if isCurrentUser, !isSavedMsg {
            Text("(You)").foregroundStyle(
              appearsActive ? .tertiary : .quaternary
            )
          }
        }
        .transaction { transaction in
          transaction.disablesAnimations = true
        }

        Spacer()
      }
    }
    .buttonStyle(UserItemButtonStyle(
      isHovered: $isHovered,
      isFocused: isFocused,
      selected: selected,
      appearsActive: appearsActive
    ))
    .focused($isFocused)
    .padding(.horizontal, -Theme.sidebarItemPadding)
    // Command-click handler
    .simultaneousGesture(
      TapGesture(count: 1)
        .modifiers(.command)
        .onEnded {
          commandPress?()
        }
    )

    if #available(macOS 14.0, *) {
      view.focusEffectDisabled()
    } else {
      view
    }
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
      .padding(.horizontal, Theme.sidebarItemPadding)
      .background {
        Group {
          RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
            .fill(backgroundColor(configuration))
        }.transaction { transaction in
          if selected {
            transaction.disablesAnimations = true
            transaction.animation = .none
          }
        }
      }
      .onHover { isHovered = $0 }
      // Optional: Add subtle scale effect when pressed
//      .scaleEffect(!selected && configuration.isPressed ? 0.98 : 1.0)
      // Optional: Add smooth animation for press state
      .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.04), value: isHovered)
      .padding(.vertical, Theme.sidebarItemSpacing)
  }

  private func backgroundColor(_ configuration: Configuration) -> Color {
    if selected {
      .primary.opacity(0.1)
    } else if configuration.isPressed {
      .primary.opacity(0.08)
    } else if isFocused {
      .primary.opacity(0.1)
    } else if isHovered {
      .primary.opacity(0.04)
    } else {
      .clear
    }
  }
}

#Preview {
  VStack(spacing: 0) {
    UserItem(user: User.preview)
    UserItem(
      user: User.preview,
      action: {
        print("Custom action")
      }
    )
  }
  .frame(width: 200)
  .previewsEnvironmentForMac(.populated)
}

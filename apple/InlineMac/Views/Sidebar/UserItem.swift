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

  var body: some View {
    let text = Text(user.firstName ?? user.username ?? "")
      .lineLimit(1)

    let view = Button {
      action?()
    } label: {
      HStack(spacing: 0) {
        UserAvatar(user: user, size: Theme.sidebarIconSize)
          .padding(.trailing, Theme.sidebarIconSpacing)

        VStack(alignment: .leading, spacing: 0) {
          if selected {
            text.foregroundColor(.white)
          } else {
            text.foregroundStyle(
              appearsActive ? .primary : .tertiary
            )
          }
        }.animation(.easeInOut(duration: 0.1), value: selected)
        Spacer()
      }
      .onHover { isHovered = $0 }
    }
    .buttonStyle(UserItemButtonStyle(
      isHovered: isHovered,
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
  let isHovered: Bool
  let isFocused: Bool
  let selected: Bool
  let appearsActive: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(height: Theme.sidebarItemHeight)
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .padding(.horizontal, Theme.sidebarItemPadding)
      .background {
        RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
          .fill(backgroundColor(configuration))
      }
      // Optional: Add subtle scale effect when pressed
      .scaleEffect(!selected && configuration.isPressed ? 0.98 : 1.0)
      // Optional: Add smooth animation for press state
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }

  private func backgroundColor(_ configuration: Configuration) -> Color {
    if selected {
      return .accentColor
    } else if configuration.isPressed {
      return .primary.opacity(0.08)
    } else if isFocused {
      return .primary.opacity(0.1)
    } else if isHovered {
      return .primary.opacity(0.05)
    } else {
      return .clear
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

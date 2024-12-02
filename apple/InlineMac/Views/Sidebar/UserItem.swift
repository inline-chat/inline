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
  var selected: Bool = false

  var backgroundColor: Color {
    if selected {
      .accentColor
    } else if isFocused {
      .primary.opacity(0.1)
    } else if isHovered {
      .primary.opacity(0.05)
    } else {
      .clear
    }
  }

  var body: some View {
    let text = Text(user.firstName ?? user.username ?? "")
      .lineLimit(1)

    let view = Button {
      if let action = action {
        action()
      }
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
        }
        Spacer()
      }
      .frame(height: Theme.sidebarItemHeight)
      .onHover { isHovered = $0 }
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .padding(.horizontal, Theme.sidebarItemPadding)
      .background {
        RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
          .fill(backgroundColor)
      }
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .padding(.horizontal, -Theme.sidebarItemPadding)

    if #available(macOS 14.0, *) {
      view.focusEffectDisabled()
    } else {
      view
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

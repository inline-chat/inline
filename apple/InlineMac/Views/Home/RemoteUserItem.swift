import InlineKit
import InlineUI
import SwiftUI

struct RemoteUserItem: View {
  @EnvironmentObject var nav: NavigationModel
  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool

  var user: ApiUser
  var action: (() -> Void)?

  var body: some View {
    let view = Button {
      if let action = action {
        action()
      }
    } label: {
      HStack(spacing: 0) {
        UserAvatar(apiUser: user)
          .padding(.trailing, Theme.sidebarIconSpacing)

        VStack(alignment: .leading, spacing: 0) {
          Text(user.firstName ?? user.username ?? "")
            .lineLimit(1)

          if let username = user.username {
            Text("@\(username)")
              .lineLimit(1)
              .foregroundStyle(.secondary)
              .font(.caption)
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
    .padding(.vertical, 2)

    if #available(macOS 14.0, *) {
      view.focusEffectDisabled()
    } else {
      view
    }
  }

  private var backgroundColor: Color {
    if isFocused {
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
    RemoteUserItem(user: ApiUser.preview)
    RemoteUserItem(
      user: ApiUser.preview,
      action: {}
    )
  }
  .frame(width: 200)
  .previewsEnvironmentForMac(.populated)
}
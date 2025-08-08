import InlineKit
import InlineUI
import SwiftUI

struct LocalSearchItem: View {
  @EnvironmentObject var nav: NavigationModel
  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool

  var item: HomeSearchResultItem
  var highlighted: Bool = false
  var action: (() -> Void)?

  var body: some View {
    let view = Button {
      if let action {
        action()
      }
    } label: {
      HStack(spacing: 0) {
        switch item {
          case let .thread(threadInfo):
            ChatIcon(peer: .chat(threadInfo.chat))
              .padding(.trailing, Theme.sidebarIconSpacing)

            VStack(alignment: .leading, spacing: 0) {
              Text(threadInfo.chat.title ?? "")
                .lineLimit(1)

              if let spaceName = threadInfo.space?.name {
                Text(spaceName)
                  .lineLimit(1)
                  .foregroundStyle(.secondary)
                  .font(.caption)
              }
            }

          case let .user(user):
            ChatIcon(peer: .user(UserInfo(user: user)))
              .padding(.trailing, Theme.sidebarIconSpacing)

            VStack(alignment: .leading, spacing: 0) {
              Text(user.displayName)
                .lineLimit(1)
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
    .padding(.vertical, 2)
    .padding(.bottom, 1)
    .padding(.horizontal, -Theme.sidebarNativeDefaultEdgeInsets + Theme.sidebarItemOuterSpacing)

    if #available(macOS 14.0, *) {
      view.focusEffectDisabled()
    } else {
      view
    }
  }

  private var backgroundColor: Color {
    if highlighted {
      .primary.opacity(0.1)
    } else if isFocused {
      .primary.opacity(0.1)
    } else if isHovered {
      .primary.opacity(0.05)
    } else {
      .clear
    }
  }
}

#Preview {
  VStack(spacing: 0) {
    LocalSearchItem(item: .thread(ThreadInfo(
      chat: Chat(
        id: 1,
        date: Date(),
        type: .thread,
        title: "Team Chat",
        spaceId: 1,
        peerUserId: nil,
        lastMsgId: nil,
        emoji: "👥"
      ),
      space: Space(id: 1, name: "Engineering", date: Date())
    )))

    LocalSearchItem(item: .user(User.preview), highlighted: true)
  }
  .frame(width: 200)
  .previewsEnvironmentForMac(.populated)
}

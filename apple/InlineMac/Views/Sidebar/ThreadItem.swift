import InlineKit
import InlineUI
import SwiftUI

struct ThreadItem: View {
  @EnvironmentObject var nav: NavigationModel
  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool
  @Environment(\.appearsActive) var appearsActive

  var thread: Chat
  var action: (() -> Void)?
  var commandPress: (() -> Void)?
  var selected: Bool = false

  // Computed
  var peerId: Peer {
    .thread(id: thread.id)
  }

  var body: some View {
    let text = Text(thread.title ?? "Untitled")
      .lineLimit(1)

    let view = Button {
      action?()
    } label: {
      HStack(spacing: 0) {
        ChatIcon(peer: .chat(thread), size: Theme.sidebarIconSize)
          .padding(.trailing, Theme.sidebarIconSpacing)

        HStack(spacing: 3) {
          text
        }
        .transaction { transaction in
          transaction.disablesAnimations = true
        }

        Spacer()
      }
      .onHover { isHovered = $0 }
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

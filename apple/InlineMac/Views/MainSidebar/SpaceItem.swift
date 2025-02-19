import InlineKit
import InlineUI
import SwiftUI

struct SpaceItem: View {
  @EnvironmentObject var dataManager: DataManager
  @EnvironmentObject var nav: Nav

  @State private var alertPresented: Bool = false
  @State private var pendingAction: Action?
  @State private var isHovered: Bool = false

  @FocusState private var isFocused: Bool
  @Environment(\.appearsActive) var appearsActive

  var space: Space

  var body: some View {
    let view = Button {
      nav.openSpace(space.id)
    } label: {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(UserItemButtonStyle(
      isHovered: $isHovered,
      isFocused: isFocused,
      selected: false,
      appearsActive: appearsActive
    ))
    .focused($isFocused)
    .padding(.horizontal, -Theme.sidebarItemPadding)

    // Alert for delete confirmation
    .alert("Are you sure?", isPresented: $alertPresented, presenting: pendingAction, actions: { action in
      Button(actionText(action), role: .destructive) {
        act(action)
      }
      Button("Cancel", role: .cancel) {
        pendingAction = nil
      }
    }, message: { action in
      Text("Confirm you want to \(actionText(action).lowercased()) this space")
    })

    // Actions on space
    .contextMenu {
      // Only creators can delete space for now
      if let creator = space.creator, creator == true {
        Button("Delete Space", role: .destructive) {
          act(.delete)
        }
      } else {
        Button("Leave Space", role: .destructive) {
          act(.leave)
        }
      }
    }

    if #available(macOS 14.0, *) {
      view.focusEffectDisabled()
    } else {
      view
    }
  }

  var content: some View {
    HStack(spacing: 0) {
      SpaceAvatar(space: space, size: Theme.sidebarIconSize)
        .padding(.trailing, Theme.sidebarIconSpacing)
      Text(space.name)
        // Text has a min height
        .lineLimit(1)

      Spacer() // Fill entire line
    }
  }

  func actionText(_ action: Action) -> String {
    action == .delete ? "Delete" : "Leave"
  }

  enum Action {
    case delete
    case leave
  }

  private func startPendingAct(_ action: Action) {
    pendingAction = action
    DispatchQueue.main.async {
      alertPresented = true
    }
  }

  private func act(_ action: Action) {
    Task {
      switch action {
        case .delete:
          if pendingAction == action {
            try await dataManager.deleteSpace(spaceId: space.id)
            navigateOutOfSpace()
          } else {
            startPendingAct(action)
          }
        case .leave:
          if pendingAction == action {
            try await dataManager.leaveSpace(spaceId: space.id)
            navigateOutOfSpace()
          } else {
            startPendingAct(action)
          }
      }
    }
  }

  private func navigateOutOfSpace() {
    // todo
  }
}

#Preview {
  SpaceItem(space: Space(name: "Space Name", date: Date()))
    .frame(width: 200)
    .previewsEnvironment(.populated)
}

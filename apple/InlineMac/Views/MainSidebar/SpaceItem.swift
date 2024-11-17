import InlineKit
import InlineUI
import SwiftUI

struct SpaceItem: View {
  @EnvironmentObject var dataManager: DataManager
  @EnvironmentObject var nav: NavigationModel

  @State private var alertPresented: Bool = false
  @State private var pendingAction: Action?
  @State private var isHovered: Bool = false

  var space: Space

  var body: some View {
    Button {
      nav.openSpace(id: space.id)
    } label: {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .focusable()
    .buttonStyle(.plain)
    .padding(.horizontal, -Theme.sidebarItemPadding)
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
    // Offset context menu border padding
    //        .padding(.vertical, -3)
    // Alert for delete confirmation
    .alert(isPresented: $alertPresented) {
      Alert(
        title: Text("Are you sure?"),
        message: Text(
          "Confirm you want to \(actionText.lowercased()) this space"
        ),
        primaryButton: .destructive(Text(actionText)) {
          Task {
            self.act(pendingAction!)
          }
        },
        secondaryButton: .cancel {
          pendingAction = nil
        }
      )
    }
  }

  var content: some View {
    HStack(spacing: 0) {
      SpaceAvatar(space: space, size: Theme.sidebarIconSize)
        .padding(.trailing, Theme.sidebarIconSpacing)
      Text(space.name)
        // Text has a min height
        .lineLimit(1)
      //                .frame(height: Theme.sidebarItemHeight)
      //                .fixedSize(horizontal: false, vertical: true)
      //                .lineSpacing(0)
      Spacer()  // Fill entire line
    }
    .frame(height: Theme.sidebarItemHeight)
    .onHover { isHovered = $0 }
    .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
    .padding(.horizontal, Theme.sidebarItemPadding)
    .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
    .cornerRadius(Theme.sidebarItemRadius)

  }

  var actionText: String {
    pendingAction == .delete ? "Delete" : "Leave"
  }

  enum Action {
    case delete
    case leave
  }

  private func startPendingAct(_ action: Action) {
    pendingAction = action
    alertPresented = true
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

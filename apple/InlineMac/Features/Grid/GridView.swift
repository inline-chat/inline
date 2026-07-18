import InlineKit
import InlineProtocol
import SwiftUI

struct GridView: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @Environment(GridRoomService.self) private var store
  @Environment(SidebarViewModel.self) private var sidebar
  let spaceID: Int64

  var body: some View {
    let title = pageTitle

    GridContent(
      grid: store.grid(spaceID: spaceID),
      isLoading: store.loadingSpaceIDs.contains(spaceID),
      didFailLoading: store.failedLoadSpaceIDs.contains(spaceID),
      audioLevel: store.audioLevel,
      connectionState: store.connectionRecoveryAttempt > 0 ? .connecting : store.media.connectionState,
      onCreate: { store.createAndJoin(spaceID: spaceID) },
      onRetry: { Task { await store.load(spaceID: spaceID) } },
      onJoin: { roomID in store.join(roomID: roomID) },
      onLeave: { store.leaveCurrentRoom(spaceID: spaceID) },
      onToggleMicrophone: { store.toggleMicrophone(spaceID: spaceID) },
      onSetTitle: { roomID, title in Task { await store.setRoomTitle(roomID: roomID, title: title) } },
      onSetLocked: { roomID, locked in Task { await store.toggleRoomLock(roomID: roomID, locked: locked) } },
      onDelete: { roomID in Task { await store.deleteRoom(roomID: roomID) } }
    )
    .navigationTitle(title)
    .toolbar(removing: .title)
    .toolbar {
      let titleItem =
        MacToolbarItem(placement: .navigation, priority: .high, label: "") {
          GridToolbarTitleItem(
            title: title,
            selectedSpaceID: spaceID,
            spaces: toolbarSpaces,
            onSelect: openGrid(spaceID:)
          )
        }

      if #available(macOS 26.0, *) {
        titleItem.sharedBackgroundVisibility(.hidden)
      } else {
        titleItem
      }

      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      ToolbarItem {
        GridAdvancedMenu(onManageHotkeys: openHotkeySettings)
      }
    }
    .safeAreaInset(edge: .bottom) {
      if currentRoom != nil {
        GridControlPill(
          media: store.media,
          onToggleMicrophone: { store.toggleMicrophone(spaceID: spaceID) },
          onLeave: { store.leaveCurrentRoom(spaceID: spaceID) },
          onSelectInput: store.setInputSelection,
          onRefreshInputDevices: store.refreshInputDevices,
          onSetOutputVolume: store.setOutputVolume,
          onRetryAudio: store.retryAudio
        )
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.smoothSnappy, value: currentRoom?.id)
    .task(id: spaceID) {
      await store.load(spaceID: spaceID)
    }
  }

  private var currentRoom: GridRoom? {
    guard let grid = store.grid(spaceID: spaceID), grid.hasCurrentRoomID else { return nil }
    return grid.rooms.first { $0.id == grid.currentRoomID }
  }

  private var pageTitle: String {
    guard let spaceName = sidebar.space(id: spaceID)?.displayName,
          spaceName.isEmpty == false
    else { return "Grid" }
    return "\(spaceName) Grid"
  }

  private var toolbarSpaces: [GridToolbarSpace] {
    store.orderedHomeSpaces.map { home in
      GridToolbarSpace(
        id: home.spaceID,
        name: sidebar.space(id: home.spaceID)?.displayName ?? "Space",
        activeAvatarCount: Int(home.activeAvatarCount)
      )
    }
  }

  private func openGrid(spaceID: Int64) {
    guard spaceID != self.spaceID else { return }
    store.recordGridOpened(spaceID: spaceID)
    nav.openGrid(spaceId: spaceID)
  }

  private func openHotkeySettings() {
    guard let dependencies else { return }
    dependencies.appBridge.openSettings(
      dependencies: dependencies,
      selectedCategory: .hotkeys
    )
  }
}

private struct GridAdvancedMenu: View {
  let onManageHotkeys: () -> Void

  var body: some View {
    Menu {
      Button(action: onManageHotkeys) {
        Label("Manage Hotkeys…", systemImage: "keyboard")
      }
    } label: {
      Label("Grid Options", systemImage: "ellipsis")
        .labelStyle(.iconOnly)
    }
    .menuIndicator(.hidden)
    .help("Grid Options")
  }
}

private struct GridToolbarSpace: Identifiable, Equatable {
  let id: Int64
  let name: String
  let activeAvatarCount: Int
}

private struct GridToolbarTitleItem: View {
  let title: String
  let selectedSpaceID: Int64
  let spaces: [GridToolbarSpace]
  let onSelect: (Int64) -> Void

  @Environment(\.macToolbarLayout) private var toolbarLayout

  @ViewBuilder
  var body: some View {
    if spaces.count > 1 {
      Menu {
        ForEach(spaces) { space in
          Button {
            onSelect(space.id)
          } label: {
            if space.id == selectedSpaceID {
              Label(menuTitle(for: space), systemImage: "checkmark")
            } else {
              Text(menuTitle(for: space))
            }
          }
        }
      } label: {
        HStack(spacing: 6) {
          Text(title)
            .font(.system(size: toolbarLayout.titleFontSize + 2, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)

          Color.clear
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(minWidth: 0, maxWidth: toolbarLayout.titleMaxWidth, alignment: .leading)
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .menuIndicator(.hidden)
      .help("Choose a Space Grid")
      .accessibilityLabel("\(title), choose a Space Grid")
    } else {
      RouteToolbarTitleItem(title: title)
    }
  }

  private func menuTitle(for space: GridToolbarSpace) -> String {
    guard space.activeAvatarCount > 0 else { return space.name }
    return "\(space.name) · \(space.activeAvatarCount) active"
  }
}

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
      isScreenSharing: store.isScreenSharing,
      connectionState: store.connectionRecoveryAttempt > 0 ? .connecting : store.media.connectionState,
      onCreate: { store.createAndJoin(spaceID: spaceID) },
      onRetry: { Task { await store.load(spaceID: spaceID) } },
      onJoin: { roomID in store.join(roomID: roomID) },
      onLeave: { store.leaveCurrentRoom(spaceID: spaceID) },
      onToggleMicrophone: { store.toggleMicrophone(spaceID: spaceID) },
      onOpenScreenShare: store.openScreenShare,
      onStopScreenShare: store.stopScreenSharing,
      onSetTitle: { roomID, title in Task { await store.setRoomTitle(roomID: roomID, title: title) } },
      onSetLocked: { roomID, locked in Task { await store.toggleRoomLock(roomID: roomID, locked: locked) } },
      onDelete: { roomID in Task { await store.deleteRoom(roomID: roomID) } }
    )
    .navigationTitle(title)
    .toolbar(removing: .title)
    .toolbar {
      let titleItem =
        MacToolbarItem(placement: .navigation, priority: .high, label: "") {
          RouteToolbarSpacePickerTitleItem(
            title: title,
            selectedSpaceID: spaceID,
            spaces: toolbarSpaces,
            help: "Choose a Space Grid",
            onSelect: { selectedSpaceID in
              guard let selectedSpaceID else { return }
              openGrid(spaceID: selectedSpaceID)
            }
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
          onSelectOutput: store.setOutputSelection,
          onRefreshOutputDevices: store.refreshOutputDevices,
          onToggleScreenShare: store.toggleScreenShare,
          onSelectScreenCaptureSource: store.startScreenSharing,
          onRefreshScreenCaptureSources: store.refreshScreenCaptureSources,
          onStopScreenShare: store.stopScreenSharing,
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

  private var toolbarSpaces: [RouteToolbarSpacePickerItem] {
    store.orderedHomeSpaces.map { home in
      RouteToolbarSpacePickerItem(
        id: home.spaceID,
        name: sidebar.space(id: home.spaceID)?.displayName ?? "Space",
        menuDetail: home.activeAvatarCount > 0 ? "\(home.activeAvatarCount) active" : nil
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

import InlineKit
import InlineProtocol
import SwiftUI

struct GridView: View {
  @Environment(GridRoomService.self) private var store
  let spaceID: Int64

  var body: some View {
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
    .navigationTitle("Grid")
    .toolbar(removing: .title)
    .toolbar {
      let titleItem =
        MacToolbarItem(placement: .navigation, priority: .high, label: "") {
          RouteToolbarTitleItem(title: "Grid")
        }

      if #available(macOS 26.0, *) {
        titleItem.sharedBackgroundVisibility(.hidden)
      } else {
        titleItem
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
}

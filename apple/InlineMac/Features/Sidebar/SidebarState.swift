import InlineKit
import Logger

final class SidebarState {
  static let shared = SidebarState()

  private init() {}

  func keepInSidebar(_ peer: Peer) {
    Task { @MainActor in
      let usesInbox = AppSettings.shared.sidebarAsInbox
      if usesInbox {
        SidebarCleanup.shared.markOpened(peer)
      }

      do {
        if peer.isThread {
          _ = try await Api.realtime.send(.showInChatList(peerId: peer))
        }
        if usesInbox {
          _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: true))
        }
      } catch {
        Log.shared.error("Failed to keep chat in sidebar", error: error)
      }
    }
  }
}

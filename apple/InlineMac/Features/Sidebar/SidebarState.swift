import InlineKit
import Logger

final class SidebarState {
  static let shared = SidebarState()

  private init() {}

  func keepInSidebar(_ peer: Peer) {
    Task { @MainActor in
      guard AppSettings.shared.sidebarAsInbox else { return }

      do {
        if peer.isThread {
          _ = try await Api.realtime.send(.showInChatList(peerId: peer))
        }
        _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: true))
      } catch {
        Log.shared.error("Failed to keep chat in sidebar", error: error)
      }
    }
  }
}

import InlineKit
import Logger

final class SidebarState {
  static let shared = SidebarState()

  private init() {}

  func keepInSidebar(_ peer: Peer) {
    keepInSidebar([peer])
  }

  func keepReplyThreadInSidebar(parentPeer: Peer, threadPeer: Peer) {
    keepInSidebar([parentPeer, threadPeer])
  }

  private func keepInSidebar(_ peers: [Peer]) {
    Task { @MainActor in
      guard AppSettings.shared.sidebarAsInbox else { return }

      do {
        // Preserve parent-before-reply ordering. A reply should never be made
        // durable in the Inbox while its semantic parent promotion is still
        // an independent fire-and-forget task.
        for peer in peers {
          SidebarCleanup.shared.markOpened(peer)
          if peer.isThread {
            _ = try await Api.realtime.send(.showInChatList(peerId: peer))
          }
          _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: true))
        }
      } catch {
        Log.shared.error("Failed to keep chat in sidebar", error: error)
      }
    }
  }
}

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
          // Only replies need promotion into the chat list. An ordinary
          // thread can be kept open immediately, even while creation is queued.
          let needsReveal: Bool
          if case let .thread(chatID) = peer {
            needsReveal = try await AppDatabase.shared.reader.read { db in
              try Chat.fetchOne(db, id: chatID)?.isReplyThread == true
            }
          } else {
            needsReveal = false
          }
          if needsReveal {
            _ = try await Api.realtime.send(.showInChatList(peerId: peer))
          }
          _ = try await Api.realtime.send(
            .updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true)
          )
        }
      } catch {
        Log.shared.error("Failed to keep chat in sidebar", error: error)
        ToastCenter.shared.showError("Couldn’t keep the chat open. Please try again.")
      }
    }
  }
}

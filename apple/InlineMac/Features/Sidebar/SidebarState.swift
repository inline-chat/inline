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

      // Preserve parent-before-reply ordering. A reply should never be made
      // durable in the Inbox while its semantic parent promotion is still
      // an independent fire-and-forget task.
      for peer in peers {
        SidebarCleanup.shared.markOpened(peer)
        do {
          try await InboxMembershipService.shared.keep(peer: peer)
        } catch {
          // Background bookkeeping for the Inbox; the user action that
          // triggered it (send, open reply) is unaffected, so this stays out
          // of the UI.
          Log.shared.error("Failed to keep chat in sidebar (peer: \(peer), reason: \(error))", error: error)
          return
        }
      }
    }
  }
}

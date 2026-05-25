import InlineKit

final class SidebarState {
  static let shared = SidebarState()

  private init() {}

  func keepInSidebar(_ peer: Peer) {
    Task { @MainActor in
      guard AppSettings.shared.sidebarAsInbox else { return }

      if peer.isThread {
        await Api.realtime.sendQueued(.showInChatList(peerId: peer))
      }
      await Api.realtime.sendQueued(.updateDialogOpen(peerId: peer, open: true))
    }
  }
}

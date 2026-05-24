import InlineKit

final class SidebarState {
  static let shared = SidebarState()

  private init() {}

  func keepInSidebar(_ peer: Peer) {
    Task { @MainActor in
      guard AppSettings.shared.sidebarAsInbox else { return }

      await Api.realtime.sendQueued(.updateDialogOpen(peerId: peer, open: true))
    }
  }
}

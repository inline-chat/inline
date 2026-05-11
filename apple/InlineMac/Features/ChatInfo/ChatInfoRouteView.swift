import InlineKit
import SwiftUI

struct ChatInfoRouteView: View {
  let peer: Peer
  let query: Nav3Route.ChatInfoQuery?

  var body: some View {
    ChatInfo(peerId: peer, defaultTab: query?.chatInfoDefaultTab)
      .id(Nav3Route.chatInfo(peer: peer, query: query))
  }
}

private extension Nav3Route.ChatInfoQuery {
  var chatInfoDefaultTab: ChatInfoDefaultTab {
    switch self {
    case .files:
      .files
    case .media:
      .media
    case .links:
      .links
    case .participants:
      .participants
    }
  }
}

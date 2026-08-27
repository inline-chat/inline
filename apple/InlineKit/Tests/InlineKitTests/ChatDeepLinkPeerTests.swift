import Foundation
@testable import InlineKit
import Testing

@Suite("Chat Deep-Link Peer")
struct ChatDeepLinkPeerTests {
  @Test("chat-index links derive the correct navigation peer")
  func derivesNavigationPeer() {
    let directMessage = Chat(
      id: 12,
      date: Date(),
      type: .privateChat,
      title: nil,
      spaceId: nil,
      peerUserId: 23
    )
    let thread = Chat(
      id: 34,
      date: Date(),
      type: .thread,
      title: "Thread",
      spaceId: nil
    )

    #expect(directMessage.deepLinkPeer == .user(id: 23))
    #expect(thread.deepLinkPeer == .thread(id: 34))
  }

  @Test("malformed private chats do not fall back to a thread peer")
  func rejectsPrivateChatWithoutUserPeer() {
    let malformedDirectMessage = Chat(
      id: 12,
      date: Date(),
      type: .privateChat,
      title: nil,
      spaceId: nil
    )

    #expect(malformedDirectMessage.deepLinkPeer == nil)
  }
}

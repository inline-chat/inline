import Foundation
import Testing

@testable import InlineKit

@Suite("Message Action Interaction State")
@MainActor
struct MessageActionInteractionStateTests {
  @Test("loading is scoped to the message revision")
  func loadingIsScopedToRevision() {
    let state = MessageActionInteractionState()
    let peer = Peer.thread(id: 44)
    let oldKey = MessageActionInteractionState.LoadingKey(
      peerId: peer,
      messageId: 10,
      rev: 1,
      actionId: "btn_1_1"
    )
    let newKey = MessageActionInteractionState.LoadingKey(
      peerId: peer,
      messageId: 10,
      rev: 2,
      actionId: "btn_1_1"
    )

    #expect(state.begin(key: oldKey))
    #expect(state.isLoading(key: oldKey))
    #expect(!state.isLoading(key: newKey))
    #expect(state.loadingActionIds(peerId: peer, messageId: 10, rev: 1) == ["btn_1_1"])
    #expect(state.loadingActionIds(peerId: peer, messageId: 10, rev: 2).isEmpty)

    state.fail(key: oldKey)
  }
}

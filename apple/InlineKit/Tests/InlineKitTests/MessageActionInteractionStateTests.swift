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

  @Test("a control's answer reaches its handler whether it lands before or after the call returns")
  func controlAnswersReachTheirHandler() {
    let state = MessageActionInteractionState()
    var heard: [String] = []
    // After: the call returned first.
    state.expectControlAnswer(7) { toast, _ in heard.append(toast ?? "") }
    state.finish(interactionId: 7, toastText: "Nothing is running.")
    // Before: the answer arrived while the call was still returning.
    state.finish(interactionId: 8, toastText: "Stopped.")
    state.expectControlAnswer(8) { toast, _ in heard.append(toast ?? "") }
    #expect(heard == ["Nothing is running.", "Stopped."])
    // Each handler runs once.
    state.finish(interactionId: 7, toastText: "again")
    #expect(heard.count == 2)
  }

  @Test("answers nothing claims are not kept forever")
  func unclaimedAnswersStayBounded() {
    let state = MessageActionInteractionState()
    for id in 1 ... 200 {
      state.finish(interactionId: Int64(id), toastText: "x")
    }
    var heard = false
    state.expectControlAnswer(1) { _, _ in heard = true }
    #expect(!heard)
    state.expectControlAnswer(200) { _, _ in heard = true }
    #expect(heard)
  }
}

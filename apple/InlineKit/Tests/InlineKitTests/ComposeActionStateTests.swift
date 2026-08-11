@testable import InlineKit
import Testing

@MainActor
@Suite("Compose action activity state")
struct ComposeActionStateTests {
  @Test("per-peer state changes without invalidating another peer")
  func perPeerStateIsIsolated() {
    let composeActions = ComposeActions()
    let firstPeer = Peer.thread(id: 101)
    let secondPeer = Peer.thread(id: 202)
    let firstState = composeActions.activityState(for: firstPeer)
    let secondState = composeActions.activityState(for: secondPeer)

    composeActions.addComposeAction(for: firstPeer, action: .typing, userId: 1)

    #expect(firstState.presentation?.action == .typing)
    #expect(firstState.presentation?.text == "typing")
    #expect(secondState.presentation == nil)

    composeActions.addComposeAction(for: firstPeer, action: .recordingVoice, userId: 1)

    #expect(firstState.presentation?.action == .recordingVoice)
    #expect(firstState.presentation?.text == "recording voice")
    #expect(secondState.presentation == nil)

    composeActions.removeAllComposeActions(for: firstPeer)
    #expect(firstState.presentation == nil)
  }

  @Test("animated presentation labels never include trailing dots")
  func animatedPresentationLabelsNeverIncludeTrailingDots() {
    let composeActions = ComposeActions()
    let actions: [ApiComposeAction] = [
      .typing,
      .uploadingPhoto,
      .uploadingDocument,
      .uploadingVideo,
      .recordingVoice,
    ]

    for (index, action) in actions.enumerated() {
      let peer = Peer.thread(id: Int64(400 + index))
      let state = composeActions.activityState(for: peer)
      composeActions.addComposeAction(for: peer, action: action, userId: 1)

      #expect(state.presentation?.text.hasSuffix(".") == false)
      #expect(state.presentation?.text.hasSuffix("…") == false)

      composeActions.removeAllComposeActions(for: peer)
    }
  }

  @Test("activity state cache does not retain rows")
  func activityStateCacheIsWeak() {
    let composeActions = ComposeActions()
    let peer = Peer.thread(id: 303)
    var state: ComposeActionActivityState? = composeActions.activityState(for: peer)
    weak let weakState = state

    state = nil

    #expect(weakState == nil)
    #expect(composeActions.activityState(for: peer).peer == peer)
  }
}

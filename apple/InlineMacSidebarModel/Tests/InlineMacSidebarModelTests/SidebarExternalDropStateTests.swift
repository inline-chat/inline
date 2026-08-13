import Testing
@testable import InlineMacSidebarModel

@Suite("Sidebar external drop target ownership")
struct SidebarExternalDropStateTests {
  private struct SemanticTarget: Hashable, Sendable {
    let rowID: String
    let peerID: Int64
    let parentPeerID: Int64?
    let userID: Int64
    let generation: Int
  }

  @Test("acceptance retains the complete semantic target value")
  func completeSemanticTargetIsFrozen() {
    var state = SidebarExternalDropState<Int, SemanticTarget>()
    let target = SemanticTarget(
      rowID: "reply",
      peerID: 42,
      parentPeerID: 7,
      userID: 1,
      generation: 9
    )

    state.updateHover(sequenceID: 1, targetID: target)
    let accepted = state.accept(sequenceID: 1)

    #expect(accepted == target)
    #expect(accepted?.parentPeerID == 7)
    #expect(accepted?.generation == 9)
  }

  @Test("hovering A then B accepts immutable target B")
  func latestSemanticTargetWins() {
    var state = SidebarExternalDropState<Int, String>()
    let targetedA = state.updateHover(sequenceID: 1, targetID: "A")
    let targetedB = state.updateHover(sequenceID: 1, targetID: "B")
    #expect(targetedA)
    #expect(targetedB)

    let accepted = state.accept(sequenceID: 1)
    #expect(accepted == "B")
    #expect(state.hoveredTargetID == nil)

    state.updateHover(sequenceID: 2, targetID: "C")
    #expect(accepted == "B")
  }

  @Test("stale exit cannot clear a newer drag sequence")
  func staleExitIsIgnored() {
    var state = SidebarExternalDropState<Int, String>()
    state.updateHover(sequenceID: 1, targetID: "A")
    state.updateHover(sequenceID: 2, targetID: "B")

    let staleExitEndedState = state.end(sequenceID: 1)
    #expect(staleExitEndedState == false)
    #expect(state.hoveredTargetID == "B")
    let accepted = state.accept(sequenceID: 2)
    #expect(accepted == "B")
  }

  @Test("disappearing target rejects acceptance")
  func missingTargetRejectsDrop() {
    var state = SidebarExternalDropState<Int, String>()
    state.updateHover(sequenceID: 1, targetID: "A")

    let accepted = state.accept(sequenceID: 1) { currentTarget in
      currentTarget != "A"
    }
    #expect(accepted == nil)
    #expect(state.hoveredTargetID == nil)
  }
}

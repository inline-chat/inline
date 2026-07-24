import Testing

@testable import InlineKit

@Suite("Grid screen-share alone grace")
struct GridScreenShareAloneGraceStateTests {
  @Test("uses the product five-second grace duration")
  func graceDuration() {
    #expect(GridScreenShareAloneGraceState.graceDuration == .seconds(5))
  }

  @Test("a share started alone remains active indefinitely")
  func startsAlone() {
    var state = GridScreenShareAloneGraceState()

    #expect(state.reconcile(context(ids: ["TR_a"])) == .cancelPendingStop)
    #expect(state.reconcile(context(ids: ["TR_a"])) == .cancelPendingStop)
    #expect(state.hasHadRemoteParticipant == false)
  }

  @Test("a peer leaving schedules one grace stop for the current publications")
  func peerLeaves() {
    var state = GridScreenShareAloneGraceState()

    #expect(
      state.reconcile(context(ids: ["TR_a"], hasRemoteParticipant: true))
        == .cancelPendingStop
    )
    #expect(
      state.reconcile(context(ids: ["TR_a"]))
        == .scheduleStop(publicationIDs: ["TR_a"])
    )
  }

  @Test("a rejoining peer cancels the stop and a later leave schedules it again")
  func peerRejoins() {
    var state = GridScreenShareAloneGraceState()
    _ = state.reconcile(context(ids: ["TR_a"], hasRemoteParticipant: true))
    _ = state.reconcile(context(ids: ["TR_a"]))

    #expect(
      state.reconcile(context(ids: ["TR_a"], hasRemoteParticipant: true))
        == .cancelPendingStop
    )
    #expect(
      state.reconcile(context(ids: ["TR_a"]))
        == .scheduleStop(publicationIDs: ["TR_a"])
    )
  }

  @Test("a reconnect publication gap preserves peer history")
  func reconnectGap() {
    var state = GridScreenShareAloneGraceState()
    _ = state.reconcile(context(ids: ["TR_old"], hasRemoteParticipant: true))

    #expect(
      state.reconcile(context(isConnected: false, ids: []))
        == .cancelPendingStop
    )
    #expect(
      state.reconcile(context(ids: ["TR_new"]))
        == .scheduleStop(publicationIDs: ["TR_new"])
    )
  }

  @Test("a new intent episode resets history even when the Stop snapshot is skipped")
  func rapidStopRestart() {
    var state = GridScreenShareAloneGraceState()
    _ = state.reconcile(context(ids: ["TR_old"], hasRemoteParticipant: true))

    #expect(
      state.reconcile(context(episodeID: 2, ids: ["TR_old"]))
        == .cancelPendingStop
    )
    #expect(state.episodeID == 2)
    #expect(state.hasHadRemoteParticipant == false)
  }

  @Test("a multi-publication replacement remains one logical sharing episode")
  func multiplePublicationReplacement() {
    var state = GridScreenShareAloneGraceState()
    _ = state.reconcile(
      context(ids: ["TR_window_a", "TR_window_b"], hasRemoteParticipant: true)
    )

    #expect(
      state.reconcile(context(ids: ["TR_window_c", "TR_window_d"]))
        == .scheduleStop(publicationIDs: ["TR_window_c", "TR_window_d"])
    )
  }

  @Test("an explicit stop resets history before a later share starts alone")
  func explicitStopResetsEpisode() {
    var state = GridScreenShareAloneGraceState()
    _ = state.reconcile(context(ids: ["TR_old"], hasRemoteParticipant: true))

    #expect(
      state.reconcile(context(ids: ["TR_old"], isShareRequested: false))
        == .reset
    )
    #expect(state.publicationIDs.isEmpty)
    #expect(state.hasHadRemoteParticipant == false)
    #expect(state.reconcile(context(ids: ["TR_new"])) == .cancelPendingStop)
  }

  @Test("a disconnected projection preserves the current sharing episode")
  func disconnectedProjection() {
    var state = GridScreenShareAloneGraceState()
    _ = state.reconcile(context(ids: ["TR_old"], hasRemoteParticipant: true))

    #expect(
      state.reconcile(context(isConnected: false, ids: ["TR_old"]))
        == .cancelPendingStop
    )
    #expect(
      state.reconcile(context(ids: ["TR_new"]))
        == .scheduleStop(publicationIDs: ["TR_new"])
    )
  }

  @Test("a scheduled stop cannot commit while the room is reconnecting")
  func staleTimerDuringReconnect() {
    let publicationIDs: Set<String> = ["TR_a"]

    #expect(
      !GridScreenShareAloneGraceState.shouldCommitScheduledStop(
        context(isConnected: false, ids: publicationIDs),
        expectedEpisodeID: 1,
        expectedPublicationIDs: publicationIDs
      )
    )
    #expect(
      GridScreenShareAloneGraceState.shouldCommitScheduledStop(
        context(ids: publicationIDs),
        expectedEpisodeID: 1,
        expectedPublicationIDs: publicationIDs
      )
    )
  }

  private func context(
    episodeID: UInt64 = 1,
    isConnected: Bool = true,
    ids: Set<String>,
    isShareRequested: Bool = true,
    hasRemoteParticipant: Bool = false
  ) -> GridScreenShareAloneGraceState.Context {
    GridScreenShareAloneGraceState.Context(
      episodeID: episodeID,
      isConnected: isConnected,
      isShareRequested: isShareRequested,
      localPublicationIDs: ids,
      hasRemoteParticipant: hasRemoteParticipant
    )
  }
}

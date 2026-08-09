import Testing

@testable import InlineKit

@Suite("Chat Open Render Trace State Tests")
struct ChatOpenRenderTraceStateTests {
  @Test("normal first-render milestones are accepted exactly once")
  func testNormalMilestonesAreRecordedOnce() {
    var state = ChatOpenRenderTrace.State()

    let recordedInitialWindow = state.record(.initialWindow)
    let recordedCachedSnapshot = state.record(.cachedSnapshot)
    let recordedFirstUIApply = state.record(.firstUIApply)
    let recordedDuplicateUIApply = state.record(.firstUIApply)

    #expect(recordedInitialWindow)
    #expect(recordedCachedSnapshot)
    #expect(recordedFirstUIApply)
    #expect(!recordedDuplicateUIApply)

    #expect(state.didRecordInitialWindow)
    #expect(state.didBuildCachedSnapshot)
    #expect(state.didApplyFirstSnapshot)
  }

  @Test("UI apply cannot complete before a cached snapshot exists")
  func testUIApplyRequiresSnapshot() {
    var state = ChatOpenRenderTrace.State()

    let recordedEarlyUIApply = state.record(.firstUIApply)
    let recordedInitialWindow = state.record(.initialWindow)
    let recordedCachedSnapshot = state.record(.cachedSnapshot)
    let recordedFirstUIApply = state.record(.firstUIApply)

    #expect(!recordedEarlyUIApply)
    #expect(recordedInitialWindow)
    #expect(recordedCachedSnapshot)
    #expect(recordedFirstUIApply)
  }

  @Test("activation outcomes remain visible without user identifiers")
  func testActivationOutcomesAreRetained() {
    var state = ChatOpenRenderTrace.State()

    let recordedReuse = state.record(.activation(.reusedInitialWindow))
    let recordedReload = state.record(.activation(.reloadedChangedWindow))

    #expect(recordedReuse)
    #expect(recordedReload)
    #expect(state.activationOutcomes == [.reusedInitialWindow, .reloadedChangedWindow])
  }

  @Test("translation completion requires its follow-up to start")
  func testTranslationCompletionRequiresStart() {
    var state = ChatOpenRenderTrace.State()

    let recordedEarlyFinish = state.record(.translationFinished)
    let recordedStart = state.record(.translationStarted)
    let recordedFinish = state.record(.translationFinished)
    let recordedDuplicateFinish = state.record(.translationFinished)

    #expect(!recordedEarlyFinish)
    #expect(recordedStart)
    #expect(recordedFinish)
    #expect(!recordedDuplicateFinish)
  }

  @Test("translation trace begins only once")
  @MainActor
  func testTranslationTraceBeginsOnlyOnce() {
    let trace = ChatOpenRenderTrace(kind: .route)

    let recordedStart = trace.recordTranslationStarted(messageCount: 3)
    let recordedDuplicateStart = trace.recordTranslationStarted(messageCount: 3)

    #expect(recordedStart)
    #expect(!recordedDuplicateStart)
    trace.cancel()
  }

  @Test("cancellation closes an incomplete first snapshot")
  func testCancellationClosesIncompleteSnapshot() {
    var state = ChatOpenRenderTrace.State()

    let recordedInitialWindow = state.record(.initialWindow)
    let recordedCancellation = state.record(.cancelled)
    let recordedLateSnapshot = state.record(.cachedSnapshot)
    let recordedLateUIApply = state.record(.firstUIApply)

    #expect(recordedInitialWindow)
    #expect(recordedCancellation)
    #expect(!recordedLateSnapshot)
    #expect(!recordedLateUIApply)
    #expect(state.wasCancelled)
  }
}

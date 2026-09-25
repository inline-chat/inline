import Testing
@testable import InlineMacSidebarModel

@Suite struct SidebarCollectionSceneAuditTests {
  @Test func oneOwnedRootIsValid() {
    let result = SidebarCollectionSceneAudit.inspect(
      ownedVisibleRootIDs: Set([1]),
      attachedRoots: [
        .init(id: 1, isAttachedInViewport: true, hasActiveAnimation: false,
              rendererChildCount: 1, nativeContentChildCount: 1),
      ]
    )

    #expect(!result.hasAnomaly)
  }

  @Test func extraDirectRootIsClassifiedWithoutAssumingOwnership() {
    let result = SidebarCollectionSceneAudit.inspect(
      ownedVisibleRootIDs: Set([1]),
      attachedRoots: [
        .init(id: 1, isAttachedInViewport: true, hasActiveAnimation: false,
              rendererChildCount: 1),
        .init(id: 2, isAttachedInViewport: true, hasActiveAnimation: false,
              rendererChildCount: 1),
      ]
    )

    #expect(result.unownedAttachedIDs == Set([2]))
    #expect(result.animatingUnownedIDs.isEmpty)
    #expect(result.unexpectedRendererIDs.isEmpty)
  }

  @Test func offscreenRootIsNotReported() {
    let result = SidebarCollectionSceneAudit.inspect(
      ownedVisibleRootIDs: Set([1]),
      attachedRoots: [
        .init(id: 1, isAttachedInViewport: true, hasActiveAnimation: false,
              rendererChildCount: 1),
        .init(id: 2, isAttachedInViewport: false, hasActiveAnimation: false,
              rendererChildCount: 1),
      ]
    )

    #expect(!result.hasAnomaly)
  }

  @Test func animationIsEvidenceRatherThanARecoveryClock() {
    let result = SidebarCollectionSceneAudit.inspect(
      ownedVisibleRootIDs: Set([1]),
      attachedRoots: [
        .init(id: 1, isAttachedInViewport: true, hasActiveAnimation: false,
              rendererChildCount: 1),
        .init(id: 2, isAttachedInViewport: true, hasActiveAnimation: true,
              rendererChildCount: 1),
      ]
    )

    #expect(result.unownedAttachedIDs == Set([2]))
    #expect(result.animatingUnownedIDs == Set([2]))
  }

  @Test func duplicatedRendererInsideOneOwnedRootIsClassified() {
    let result = SidebarCollectionSceneAudit.inspect(
      ownedVisibleRootIDs: Set([1]),
      attachedRoots: [
        .init(id: 1, isAttachedInViewport: true, hasActiveAnimation: false,
              rendererChildCount: 2, nativeContentChildCount: 1),
      ]
    )

    #expect(result.unownedAttachedIDs.isEmpty)
    #expect(result.unexpectedRendererIDs == Set([1]))
  }

  @Test func duplicatedNativeContentInsideOneRendererIsClassified() {
    let result = SidebarCollectionSceneAudit.inspect(
      ownedVisibleRootIDs: Set([1]),
      attachedRoots: [
        .init(id: 1, isAttachedInViewport: true, hasActiveAnimation: false,
              rendererChildCount: 1, nativeContentChildCount: 2),
      ]
    )

    #expect(result.unexpectedRendererIDs == Set([1]))
  }

  @Test func didEndThenWillDisplayTracksReuseAtTheNewPosition() {
    var ledger = SidebarCollectionLifecycleLedger<Int, Int>()
    ledger.willDisplay(4, at: 1)
    #expect(ledger.displayed[4]?.position == 1)
    ledger.didEndDisplaying(4, at: 1)
    #expect(ledger.displayed[4] == nil)
    #expect(ledger.lastEvent(for: 4)?.kind == .didEndDisplaying)
    #expect(ledger.lastEvent(for: 4)?.position == 1)
    ledger.willDisplay(4, at: 7)
    #expect(ledger.displayed[4]?.position == 7)
    #expect(ledger.displayed[4]?.willDisplaySequence == 3)
    #expect(ledger.lastEvent(for: 4)?.kind == .willDisplay)
  }

  @Test func staleDidEndDoesNotEraseAReusedRoot() {
    var ledger = SidebarCollectionLifecycleLedger<Int, Int>()
    ledger.willDisplay(4, at: 1)
    ledger.willDisplay(4, at: 7)
    ledger.didEndDisplaying(4, at: 1)
    #expect(ledger.displayed[4]?.position == 7)
    #expect(ledger.lastEvent(for: 4)?.kind == .didEndDisplaying)
  }

  @Test func recentEventHistoryIsBounded() {
    var ledger = SidebarCollectionLifecycleLedger<Int, Int>()
    ledger.willDisplay(1, at: 1)
    for id in 2...130 {
      ledger.willDisplay(id, at: id)
    }
    #expect(ledger.lastEvent(for: 1) == nil)
    #expect(ledger.lastEvent(for: 130)?.sequence == 130)
  }
}

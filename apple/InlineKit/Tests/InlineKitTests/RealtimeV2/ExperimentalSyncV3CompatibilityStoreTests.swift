import Testing

@testable import RealtimeV2

@Suite("Experimental Sync V3 atomic compatibility store")
struct SyncV3CompatibilityStoreTests {
  typealias Store = ExperimentalSyncV3CompatibilityStore

  private let bucket = Store.Bucket(accountID: 7, kind: .chat(42))
  private let lease = Store.Lease(generation: 1, writer: .v3)

  @Test("every injected pre-commit failure rolls back models, receipts, effects, and cursor")
  func injectedFailuresAreAtomic() async throws {
    for point in Store.FailurePoint.allCases {
      let store = Store(bucket: bucket)
      let before = await store.snapshot()

      await #expect(throws: Store.CommitError.injectedFailure(point)) {
        try await store.commit(makePage(), lease: lease, injecting: point)
      }
      #expect(await store.snapshot() == before)
    }
  }

  @Test("committed page replay is idempotent")
  func committedPageReplayIsIdempotent() async throws {
    let store = Store(bucket: bucket)
    let page = makePage()

    #expect(try await store.commit(page, lease: lease) == .applied)
    let committed = await store.snapshot()
    #expect(try await store.commit(page, lease: lease) == .replayed)
    #expect(await store.snapshot() == committed)
    #expect(committed.pendingEffectIDs == ["notify-3"])
  }

  @Test("sidecar dependency closure is validated before cursor proof")
  func sidecarDependencyClosure() async throws {
    let missingStore = Store(bucket: bucket)
    let missingPage = makeModelPage(sidecars: [])

    await #expect(throws: Store.CommitError.missingDependency(900)) {
      try await missingStore.commit(missingPage, lease: lease)
    }
    #expect(await missingStore.snapshot() == .empty)

    let closedStore = Store(bucket: bucket)
    let closedPage = makeModelPage(sidecars: [900])
    #expect(try await closedStore.commit(closedPage, lease: lease) == .applied)
    #expect(await closedStore.snapshot().modelIDs == [100, 900])
  }

  @Test("unknown durable semantics block the exact sequence")
  func unknownDurableKindBlocksCursor() async throws {
    let store = Store(bucket: bucket)
    let page = Store.Page(
      id: "unknown",
      bucket: bucket,
      startSequence: 0,
      endSequence: 1,
      sidecarModelIDs: [],
      envelopes: [
        Store.Envelope(
          bucket: bucket,
          previousSequence: 0,
          sequence: 1,
          semantic: .unknown(kind: 404)
        ),
      ]
    )

    await #expect(throws: Store.CommitError.unknownDurableKind(404)) {
      try await store.commit(page, lease: lease)
    }
    #expect(await store.snapshot().sequence == 0)
  }

  @Test("future, reordered, and unaccounted pages cannot advance")
  func malformedPagesCannotAdvance() async throws {
    let store = Store(bucket: bucket)
    let future = Store.Page(
      id: "future",
      bucket: bucket,
      startSequence: 4,
      endSequence: 5,
      sidecarModelIDs: [],
      envelopes: []
    )
    await #expect(throws: Store.CommitError.staleOrFutureStart(expected: 0, actual: 4)) {
      try await store.commit(future, lease: lease)
    }

    let reordered = Store.Page(
      id: "reordered",
      bucket: bucket,
      startSequence: 0,
      endSequence: 2,
      sidecarModelIDs: [],
      envelopes: [
        Store.Envelope(bucket: bucket, previousSequence: 1, sequence: 2, semantic: .noEffect(receipt: "2")),
        Store.Envelope(bucket: bucket, previousSequence: 0, sequence: 1, semantic: .noEffect(receipt: "1")),
      ]
    )
    await #expect(throws: Store.CommitError.nonContiguous(expectedPrevious: 0, actualPrevious: 1, sequence: 2)) {
      try await store.commit(reordered, lease: lease)
    }

    let unaccounted = Store.Page(
      id: "unaccounted",
      bucket: bucket,
      startSequence: 0,
      endSequence: 2,
      sidecarModelIDs: [],
      envelopes: [
        Store.Envelope(bucket: bucket, previousSequence: 0, sequence: 1, semantic: .noEffect(receipt: "1")),
      ]
    )
    await #expect(throws: Store.CommitError.unaccountedSequence(expectedEnd: 2, actualEnd: 1)) {
      try await store.commit(unaccounted, lease: lease)
    }
    #expect(await store.snapshot() == .empty)
  }

  @Test("typed TOO_LONG replacement commits coverage and state together")
  func repairReplacementIsAtomic() async throws {
    let initial = Store.Snapshot(
      sequence: 2,
      modelIDs: [1, 2],
      noEffectReceipts: [],
      pendingEffectIDs: [],
      coverageReceipts: [],
      committedUnitIDs: [:]
    )
    let repair = Store.Repair(
      id: "repair-8",
      bucket: bucket,
      throughSequence: 8,
      modelIDs: [8, 9],
      coverageReceipt: "replaced-through-8",
      mode: .replace
    )

    for point in [Store.FailurePoint.afterSidecars, .beforeCursor, .afterCursorBeforeCommit] {
      let store = Store(bucket: bucket, state: initial)
      await #expect(throws: Store.CommitError.injectedFailure(point)) {
        try await store.commitRepair(repair, lease: lease, injecting: point)
      }
      #expect(await store.snapshot() == initial)
    }

    let store = Store(bucket: bucket, state: initial)
    #expect(try await store.commitRepair(repair, lease: lease) == .applied)
    let repaired = await store.snapshot()
    #expect(repaired.sequence == 8)
    #expect(repaired.modelIDs == [8, 9])
    #expect(repaired.coverageReceipts == ["replaced-through-8"])
    #expect(try await store.commitRepair(repair, lease: lease) == .replayed)
  }

  @Test("legacy writer and stale account generations cannot commit")
  func writerExclusivityAndGenerationFence() async throws {
    let store = Store(bucket: bucket)
    let page = makePage()

    await #expect(throws: Store.CommitError.wrongWriter) {
      try await store.commit(page, lease: .init(generation: 1, writer: .legacy))
    }
    await store.replaceGeneration(with: 2)
    await #expect(throws: Store.CommitError.staleGeneration(expected: 2, actual: 1)) {
      try await store.commit(page, lease: lease)
    }
    #expect(await store.snapshot() == .empty)
  }

  @Test("deterministic generated pages preserve contiguous proof under replay")
  func generatedReplayProperty() async throws {
    for count in 1 ... 64 {
      let store = Store(bucket: bucket)
      let envelopes = (1 ... count).map { sequence in
        Store.Envelope(
          bucket: bucket,
          previousSequence: Int64(sequence - 1),
          sequence: Int64(sequence),
          semantic: sequence.isMultiple(of: 3)
            ? .durableEffect(id: "effect-\(sequence)")
            : .noEffect(receipt: "receipt-\(sequence)")
        )
      }
      let page = Store.Page(
        id: "generated-\(count)",
        bucket: bucket,
        startSequence: 0,
        endSequence: Int64(count),
        sidecarModelIDs: [],
        envelopes: envelopes
      )

      #expect(try await store.commit(page, lease: lease) == .applied)
      let committed = await store.snapshot()
      #expect(committed.sequence == Int64(count))
      #expect(try await store.commit(page, lease: lease) == .replayed)
      #expect(await store.snapshot() == committed)
    }
  }

  private func makePage() -> Store.Page {
    Store.Page(
      id: "page-1-3",
      bucket: bucket,
      startSequence: 0,
      endSequence: 3,
      sidecarModelIDs: [900],
      envelopes: [
        Store.Envelope(
          bucket: bucket,
          previousSequence: 0,
          sequence: 1,
          semantic: .model(id: 100, dependsOn: 900)
        ),
        Store.Envelope(
          bucket: bucket,
          previousSequence: 1,
          sequence: 2,
          semantic: .noEffect(receipt: "no-effect-2")
        ),
        Store.Envelope(
          bucket: bucket,
          previousSequence: 2,
          sequence: 3,
          semantic: .durableEffect(id: "notify-3")
        ),
      ]
    )
  }

  private func makeModelPage(sidecars: Set<Int64>) -> Store.Page {
    Store.Page(
      id: "model-page",
      bucket: bucket,
      startSequence: 0,
      endSequence: 1,
      sidecarModelIDs: sidecars,
      envelopes: [
        Store.Envelope(
          bucket: bucket,
          previousSequence: 0,
          sequence: 1,
          semantic: .model(id: 100, dependsOn: 900)
        ),
      ]
    )
  }
}

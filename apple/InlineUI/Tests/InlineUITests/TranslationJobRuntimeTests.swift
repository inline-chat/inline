import Foundation
import InlineKit
@testable import Translation
import Testing

@Suite("Account-scoped translation job runtime")
struct TranslationJobRuntimeTests {
  @Test("duplicates coalesce and database acknowledgement is success authority")
  func duplicateAndAcknowledgement() async throws {
    let probe = DispatchProbe()
    let runtime = makeRuntime(probe: probe, persistenceTimeout: .seconds(1))
    let identity = jobIdentity(1)

    try await runtime.submit([
      TranslationJob(identity: identity, priority: .background),
      TranslationJob(identity: identity, priority: .openChat),
    ])
    try await eventually { await probe.callCount == 1 }
    await runtime.acknowledgePersisted([identity])
    try await eventually { await runtime.snapshot().awaitingPersistence == 0 }

    #expect(await probe.flattened == [identity])
    #expect(await runtime.snapshot().pending == 0)
    await runtime.shutdown()
  }

  @Test("already-persisted translations never dispatch")
  func persistedBeforeDispatch() async throws {
    let identity = jobIdentity(2)
    let probe = DispatchProbe(persisted: [identity])
    let runtime = makeRuntime(probe: probe)

    try await runtime.submit([TranslationJob(identity: identity, priority: .visiblePreview)])
    try await eventually {
      let snapshot = await runtime.snapshot()
      return snapshot.pending + snapshot.dispatching + snapshot.awaitingPersistence + snapshot.retrying == 0
    }

    #expect(await probe.callCount == 0)
    #expect(await runtime.snapshot().awaitingPersistence == 0)
    await runtime.shutdown()
  }

  @Test("higher priority jobs lead a bounded batch")
  func visiblePriority() async throws {
    let probe = DispatchProbe()
    let runtime = makeRuntime(probe: probe, batchLimit: 2, persistenceTimeout: .seconds(1))
    let background = jobIdentity(3)
    let visible = jobIdentity(4)
    let openChat = jobIdentity(5)

    try await runtime.submit([
      TranslationJob(identity: background, priority: .background),
      TranslationJob(identity: visible, priority: .visiblePreview),
      TranslationJob(identity: openChat, priority: .openChat),
    ])
    try await eventually { await probe.callCount >= 1 }

    #expect(await probe.batches.first == [openChat, visible])
    await runtime.shutdown()
  }

  @Test("missing persistence acknowledgement retries only to the attempt bound")
  func boundedPersistenceRetry() async throws {
    let probe = DispatchProbe()
    let runtime = makeRuntime(
      probe: probe,
      maximumAttempts: 2,
      persistenceTimeout: .milliseconds(15),
      retryDelay: .milliseconds(5)
    )

    try await runtime.submit([
      TranslationJob(identity: jobIdentity(6), priority: .visiblePreview),
    ])
    try await eventually(timeout: .seconds(1)) {
      await runtime.snapshot().exhausted == 1
    }

    #expect(await probe.callCount == 2)
    await runtime.shutdown()
  }

  @Test("dispatch failures back off and recover")
  func dispatchFailureRecovery() async throws {
    let probe = DispatchProbe(failuresRemaining: 1)
    let runtime = makeRuntime(
      probe: probe,
      maximumAttempts: 3,
      persistenceTimeout: .seconds(1),
      retryDelay: .milliseconds(5)
    )
    let identity = jobIdentity(7)

    try await runtime.submit([TranslationJob(identity: identity, priority: .openChat)])
    try await eventually { await probe.callCount == 2 }
    await runtime.acknowledgePersisted([identity])

    #expect(await runtime.snapshot().exhausted == 0)
    await runtime.shutdown()
  }

  @Test("shutdown joins work and rejects later submissions")
  func shutdown() async throws {
    let probe = DispatchProbe()
    let runtime = makeRuntime(probe: probe, persistenceTimeout: .seconds(30))
    try await runtime.submit([
      TranslationJob(identity: jobIdentity(8), priority: .background),
    ])
    try await eventually { await probe.callCount == 1 }

    await runtime.shutdown()
    let snapshot = await runtime.snapshot()
    #expect(snapshot.isShutdown)
    #expect(snapshot.pending == 0)
    #expect(snapshot.awaitingPersistence == 0)

    await #expect(throws: TranslationJobRuntime.RuntimeError.shutdown) {
      try await runtime.submit([
        TranslationJob(identity: jobIdentity(9), priority: .openChat),
      ])
    }
  }

  private func makeRuntime(
    probe: DispatchProbe,
    batchLimit: Int = 24,
    maximumAttempts: Int = 3,
    persistenceTimeout: Duration = .milliseconds(100),
    retryDelay: Duration = .milliseconds(5)
  ) -> TranslationJobRuntime {
    TranslationJobRuntime(
      accountID: 42,
      configuration: .init(
        batchLimit: batchLimit,
        maximumAttempts: maximumAttempts,
        persistenceTimeout: persistenceTimeout,
        baseRetryDelay: retryDelay,
        maximumRetryDelay: retryDelay
      ),
      dependencies: .init(
        loadPersisted: { identities in
          await probe.loadPersisted(identities)
        },
        dispatch: { identities in
          try await probe.dispatch(identities)
        }
      )
    )
  }

  private func jobIdentity(_ id: Int64) -> TranslationJobIdentity {
    TranslationJobIdentity(
      peer: .thread(id: id),
      chatID: id,
      messageID: id * 10,
      messageRevision: 1,
      language: "en"
    )
  }

  private func eventually(
    timeout: Duration = .milliseconds(500),
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
      guard clock.now < deadline else {
        Issue.record("condition was not met before timeout")
        return
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}

private actor DispatchProbe {
  enum ProbeError: Error {
    case planned
  }

  private(set) var batches: [[TranslationJobIdentity]] = []
  private(set) var persisted: Set<TranslationJobIdentity>
  private var failuresRemaining: Int

  init(
    persisted: Set<TranslationJobIdentity> = [],
    failuresRemaining: Int = 0
  ) {
    self.persisted = persisted
    self.failuresRemaining = failuresRemaining
  }

  var callCount: Int {
    batches.count
  }

  var flattened: [TranslationJobIdentity] {
    batches.flatMap(\.self)
  }

  func loadPersisted(_ identities: [TranslationJobIdentity]) -> Set<TranslationJobIdentity> {
    Set(identities).intersection(persisted)
  }

  func dispatch(_ identities: [TranslationJobIdentity]) throws {
    batches.append(identities)
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw ProbeError.planned
    }
  }
}

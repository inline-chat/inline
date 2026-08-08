import Foundation
import RealtimeV2
import Testing

private actor AccountRuntimeProbe {
  private var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }

  func snapshot() -> [String] {
    events
  }
}

@Suite("Account generation supervisor")
struct AccountGenerationSupervisorTests {
  @Test("account replacement cancels and joins the previous child")
  func replacementDrainsPreviousGeneration() async throws {
    let supervisor = AccountGenerationSupervisor()
    let probe = AccountRuntimeProbe()
    let started = AsyncStream.makeStream(of: Void.self)
    let first = await supervisor.begin(accountID: 10)

    let accepted = await supervisor.startChild(for: first) {
      started.continuation.yield()
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        await probe.record("child-cancelled")
      }
    }
    #expect(accepted)

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    let second = await supervisor.begin(accountID: 20)

    #expect(second.accountID == 20)
    #expect(second.epoch > first.epoch)
    #expect(await probe.snapshot() == ["child-cancelled"])
    #expect(await supervisor.snapshot().ownedChildCount == 0)
  }

  @Test("a stale generation cannot start work or commit")
  func staleGenerationIsRejected() async {
    let supervisor = AccountGenerationSupervisor()
    let first = await supervisor.begin(accountID: 10)
    let second = await supervisor.begin(accountID: 10)

    let started = await supervisor.startChild(for: first) {}
    let staleCommit: String? = await supervisor.commitIfCurrent(first) { "stale" }
    let currentCommit: String? = await supervisor.commitIfCurrent(second) { "current" }

    #expect(!started)
    #expect(staleCommit == nil)
    #expect(currentCommit == "current")
  }

  @Test("cleanup runs after children and in reverse acquisition order")
  func cleanupOrdering() async {
    let supervisor = AccountGenerationSupervisor()
    let probe = AccountRuntimeProbe()
    let generation = await supervisor.begin(accountID: 10)

    _ = await supervisor.startChild(for: generation) {
      while !Task.isCancelled {
        await Task.yield()
      }
      await probe.record("child-ended")
    }
    _ = await supervisor.registerCleanup(for: generation, label: "database") {
      await probe.record("database-cleanup")
    }
    _ = await supervisor.registerCleanup(for: generation, label: "realtime") {
      await probe.record("realtime-cleanup")
    }

    await supervisor.logout()

    #expect(await probe.snapshot() == [
      "child-ended",
      "realtime-cleanup",
      "database-cleanup",
    ])
    #expect(await supervisor.snapshot().generation == nil)
  }

  @Test("overlapping replacements cannot overtake an in-flight drain")
  func overlappingReplacementsAreSerialized() async {
    let supervisor = AccountGenerationSupervisor()
    let cleanupStarted = AsyncStream.makeStream(of: Void.self)
    let cleanupRelease = AsyncStream.makeStream(of: Void.self)
    let first = await supervisor.begin(accountID: 10)
    _ = await supervisor.registerCleanup(for: first, label: "slow-cleanup") {
      cleanupStarted.continuation.yield()
      var releaseIterator = cleanupRelease.stream.makeAsyncIterator()
      _ = await releaseIterator.next()
    }

    let secondTask = Task { await supervisor.begin(accountID: 20) }
    var startedIterator = cleanupStarted.stream.makeAsyncIterator()
    _ = await startedIterator.next()
    let thirdTask = Task { await supervisor.begin(accountID: 30) }
    await Task.yield()
    cleanupRelease.continuation.yield()

    let second = await secondTask.value
    let third = await thirdTask.value
    let finalGeneration = await supervisor.snapshot().generation

    #expect(second.accountID == 20)
    #expect(third.accountID == 30)
    #expect(third.epoch > second.epoch)
    #expect(finalGeneration == third)
  }

  @Test("persistence scope survives generations but changes with account")
  func persistenceScopeUsesAccountIdentity() {
    #expect(AccountPersistenceScope(accountID: 10).relativeDirectory == "accounts/10")
    #expect(AccountPersistenceScope(accountID: 10) == AccountPersistenceScope(accountID: 10))
    #expect(AccountPersistenceScope(accountID: 10) != AccountPersistenceScope(accountID: 20))
  }
}

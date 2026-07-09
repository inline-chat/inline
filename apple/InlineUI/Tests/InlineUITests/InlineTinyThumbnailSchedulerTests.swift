import Foundation
import Testing

@testable import InlineUI

@Suite("Inline tiny thumbnail scheduler")
struct InlineTinyThumbnailSchedulerTests {
  @Test("visible requests promote queued speculative work")
  func visibleRequestsPromoteSpeculativeWork() async {
    let probe = ThumbnailSchedulerProbe(blockedKeys: [1])
    let scheduler = makeScheduler(probe: probe)

    await scheduler.prewarm(keys: [1, 2], priority: .speculative, ownerID: UUID())
    await probe.waitUntilStarted(count: 1)
    await scheduler.prewarm(keys: [3], priority: .speculative, ownerID: UUID())

    let visibleValue = Task {
      await scheduler.value(for: 3, priority: .visible)
    }
    while await scheduler.priority(for: 3) != .visible {
      await Task.yield()
    }

    await probe.release(key: 1)
    #expect(await visibleValue.value == "3")
    await scheduler.waitUntilIdle()
    #expect(await probe.startedKeys() == [1, 3, 2])
  }

  @Test("cancelling an owner drops its queued work")
  func cancellingOwnerDropsQueuedWork() async {
    let probe = ThumbnailSchedulerProbe(blockedKeys: [1])
    let scheduler = makeScheduler(probe: probe)
    let cancelledOwner = UUID()

    await scheduler.prewarm(keys: [1], priority: .visible, ownerID: UUID())
    await probe.waitUntilStarted(count: 1)
    await scheduler.prewarm(keys: [2], priority: .nearby, ownerID: cancelledOwner)
    await scheduler.cancel(ownerID: cancelledOwner)
    await probe.release(key: 1)

    await scheduler.waitUntilIdle()
    #expect(await probe.startedKeys() == [1])
  }

  @Test("shared queued work survives one owner cancellation")
  func sharedQueuedWorkSurvivesOneOwnerCancellation() async {
    let probe = ThumbnailSchedulerProbe(blockedKeys: [1])
    let scheduler = makeScheduler(probe: probe)
    let retainedOwner = UUID()
    let cancelledOwner = UUID()

    await scheduler.prewarm(keys: [1], priority: .visible, ownerID: UUID())
    await probe.waitUntilStarted(count: 1)
    await scheduler.prewarm(keys: [2], priority: .nearby, ownerID: retainedOwner)
    await scheduler.prewarm(keys: [2], priority: .nearby, ownerID: cancelledOwner)
    await scheduler.cancel(ownerID: cancelledOwner)
    await probe.release(key: 1)

    await scheduler.waitUntilIdle()
    #expect(await probe.startedKeys() == [1, 2])
  }

  @Test("cancelling a visible waiter drops stale queued work")
  func cancellingVisibleWaiterDropsQueuedWork() async {
    let probe = ThumbnailSchedulerProbe(blockedKeys: [1])
    let scheduler = makeScheduler(probe: probe)

    await scheduler.prewarm(keys: [1], priority: .visible, ownerID: UUID())
    await probe.waitUntilStarted(count: 1)
    let staleVisibleValue = Task {
      await scheduler.value(for: 2, priority: .visible)
    }
    while await scheduler.priority(for: 2) != .visible {
      await Task.yield()
    }

    staleVisibleValue.cancel()
    #expect(await staleVisibleValue.value == nil)
    await probe.release(key: 1)

    await scheduler.waitUntilIdle()
    #expect(await probe.startedKeys() == [1])
  }

  @Test("speculative backlog stays bounded while preserving batch order")
  func speculativeBacklogStaysBounded() async {
    let probe = ThumbnailSchedulerProbe(blockedKeys: [1])
    let scheduler = makeScheduler(probe: probe, maxQueuedSpeculativeJobs: 2)

    await scheduler.prewarm(keys: [1], priority: .visible, ownerID: UUID())
    await probe.waitUntilStarted(count: 1)
    await scheduler.prewarm(keys: [2, 3, 4], priority: .speculative, ownerID: UUID())
    await probe.release(key: 1)

    await scheduler.waitUntilIdle()
    #expect(await probe.startedKeys() == [1, 2, 3])
  }

  private func makeScheduler(
    probe: ThumbnailSchedulerProbe,
    maxQueuedSpeculativeJobs: Int = 48
  ) -> TinyThumbnailRenderScheduler<Int, String> {
    TinyThumbnailRenderScheduler(
      maxQueuedSpeculativeJobs: maxQueuedSpeculativeJobs,
      cachedValue: { _ in nil },
      render: { key, priority, queueWait in
        _ = priority
        _ = queueWait
        return await probe.render(key)
      }
    )
  }
}

private actor ThumbnailSchedulerProbe {
  private let blockedKeys: Set<Int>
  private var started: [Int] = []
  private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

  init(blockedKeys: Set<Int>) {
    self.blockedKeys = blockedKeys
  }

  func render(_ key: Int) async -> String {
    started.append(key)
    if blockedKeys.contains(key) {
      await withCheckedContinuation { continuation in
        continuations[key] = continuation
      }
    }
    return String(key)
  }

  func waitUntilStarted(count: Int) async {
    while started.count < count {
      await Task.yield()
    }
  }

  func release(key: Int) {
    continuations.removeValue(forKey: key)?.resume()
  }

  func startedKeys() -> [Int] {
    started
  }
}

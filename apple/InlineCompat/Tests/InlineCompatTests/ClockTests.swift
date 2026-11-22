import Darwin
import Foundation
@testable import InlineCompat
import Testing

private struct WorkError: Error, Equatable {}

@Suite("Compat clocks")
struct ClockTests {
  // MARK: Instants

  @Test("continuous clock never goes backwards")
  func continuousMonotonic() {
    var previous = CompatContinuousClock.now
    for _ in 0 ..< 10_000 {
      let next = CompatContinuousClock.now
      #expect(next >= previous)
      previous = next
    }
  }

  @Test("suspending clock never goes backwards")
  func suspendingMonotonic() {
    var previous = CompatSuspendingClock.now
    for _ in 0 ..< 10_000 {
      let next = CompatSuspendingClock.now
      #expect(next >= previous)
      previous = next
    }
  }

  @Test("instance, static and Instant.now agree")
  func nowSpellings() {
    let continuous = CompatContinuousClock()
    let a = CompatContinuousClock.now
    let b = continuous.now
    let c = CompatContinuousClock.Instant.now
    #expect(a <= b && b <= c)
    #expect(a.duration(to: c) < .milliseconds(50))

    let suspending = CompatSuspendingClock()
    let d = CompatSuspendingClock.now
    let e = suspending.now
    let f = CompatSuspendingClock.Instant.now
    #expect(d <= e && e <= f)
    #expect(d.duration(to: f) < .milliseconds(50))
  }

  @Test("continuous clock reads the same base as CLOCK_MONOTONIC_RAW")
  func continuousMatchesSystemClock() {
    let before = Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    let compat = CompatContinuousClock.now.uptimeNanoseconds
    let after = Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    // Allow a microsecond for rounding differences in the timebase conversion.
    #expect(compat >= before - 1000)
    #expect(compat <= after + 1000)
  }

  @Test("suspending clock reads the same base as CLOCK_UPTIME_RAW")
  func suspendingMatchesSystemClock() {
    let before = Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    let compat = CompatSuspendingClock.now.uptimeNanoseconds
    let after = Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    #expect(compat >= before - 1000)
    #expect(compat <= after + 1000)
  }

  @Test("continuous time includes suspending time")
  func continuousAtLeastSuspending() {
    let suspending = CompatSuspendingClock.now.uptimeNanoseconds
    let continuous = CompatContinuousClock.now.uptimeNanoseconds
    #expect(continuous >= suspending)
  }

  @Test("continuous clock deltas track ContinuousClock")
  func continuousTracksNative() {
    let native0 = Swift.ContinuousClock.now
    let compat0 = CompatContinuousClock.now
    Thread.sleep(forTimeInterval: 0.02)
    let compat1 = CompatContinuousClock.now
    let native1 = Swift.ContinuousClock.now

    let nativeDelta = CompatDuration(native1 - native0)
    let compatDelta = compat1 - compat0
    // The compat interval is nested inside the native one.
    #expect(compatDelta >= .milliseconds(20))
    #expect(compatDelta <= nativeDelta + .microseconds(1))
    #expect(nativeDelta - compatDelta < .milliseconds(5))
  }

  @Test("suspending clock deltas track SuspendingClock")
  func suspendingTracksNative() {
    let native0 = Swift.SuspendingClock.now
    let compat0 = CompatSuspendingClock.now
    Thread.sleep(forTimeInterval: 0.02)
    let compat1 = CompatSuspendingClock.now
    let native1 = Swift.SuspendingClock.now

    let nativeDelta = CompatDuration(native1 - native0)
    let compatDelta = compat1 - compat0
    #expect(compatDelta >= .milliseconds(20))
    #expect(compatDelta <= nativeDelta + .microseconds(1))
    #expect(nativeDelta - compatDelta < .milliseconds(5))
  }

  @Test("continuous instant arithmetic")
  func continuousInstantArithmetic() {
    let start = CompatContinuousClock.Instant(uptimeNanoseconds: 1_000_000_000)
    let later = start.advanced(by: .milliseconds(250))
    #expect(later.uptimeNanoseconds == 1_250_000_000)
    #expect(start.duration(to: later) == .milliseconds(250))
    #expect(later.duration(to: start) == .milliseconds(-250))
    #expect(start + .milliseconds(250) == later)
    #expect(later - .milliseconds(250) == start)
    #expect(later - start == .milliseconds(250))
    #expect(start - later == .milliseconds(-250))
    #expect(start.advanced(by: .seconds(-1)).uptimeNanoseconds == 0)
    #expect(start < later)
    #expect(!(later < start))

    var moving = start
    moving += .seconds(2)
    #expect(moving.uptimeNanoseconds == 3_000_000_000)
    moving -= .milliseconds(500)
    #expect(moving.uptimeNanoseconds == 2_500_000_000)
    #expect(start.description == "Instant(1000000000ns)")

    let set: Set = [start, start + .zero, later]
    #expect(set.count == 2)
  }

  @Test("suspending instant arithmetic")
  func suspendingInstantArithmetic() {
    let start = CompatSuspendingClock.Instant(uptimeNanoseconds: 5_000)
    let later = start.advanced(by: .nanoseconds(1_500))
    #expect(later.uptimeNanoseconds == 6_500)
    #expect(start.duration(to: later) == .nanoseconds(1_500))
    #expect(later.duration(to: start) == .nanoseconds(-1_500))
    #expect(start + .nanoseconds(1_500) == later)
    #expect(later - .nanoseconds(1_500) == start)
    #expect(later - start == .nanoseconds(1_500))
    #expect(start < later)
    #expect([later, start].sorted() == [start, later])
  }

  @Test("minimumResolution is one nanosecond")
  func resolution() {
    #expect(CompatContinuousClock().minimumResolution == .nanoseconds(1))
  }

  // MARK: measure

  @Test("measure returns at least the time the work took")
  func measureSync() {
    let continuous = CompatContinuousClock().measure { Thread.sleep(forTimeInterval: 0.01) }
    #expect(continuous >= .milliseconds(10))
    #expect(continuous < .seconds(2))

    let suspending = CompatSuspendingClock().measure { Thread.sleep(forTimeInterval: 0.01) }
    #expect(suspending >= .milliseconds(10))
    #expect(suspending < .seconds(2))

    let empty = CompatContinuousClock().measure {}
    #expect(empty >= .zero)
    #expect(empty < .milliseconds(50))
  }

  @Test("measure rethrows")
  func measureRethrows() {
    #expect(throws: WorkError()) {
      _ = try CompatContinuousClock().measure { throw WorkError() }
    }
    #expect(throws: WorkError()) {
      _ = try CompatSuspendingClock().measure { throw WorkError() }
    }
  }

  @Test("async measure covers the awaited work")
  func measureAsync() async throws {
    let elapsed = try await CompatContinuousClock().measure {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(elapsed >= .milliseconds(10))
    #expect(elapsed < .seconds(2))

    await #expect(throws: WorkError()) {
      _ = try await CompatContinuousClock().measure {
        await Task.yield()
        throw WorkError()
      }
    }
  }

  @MainActor
  @Test("async measure keeps the caller's isolation")
  func measureAsyncIsolation() async {
    var ranOnMain = false
    _ = await CompatContinuousClock().measure {
      await Task.yield()
      ranOnMain = pthread_main_np() != 0
    }
    #expect(ranOnMain)
  }

  // MARK: Sleeping

  @Test("Task.sleep(for:) sleeps at least the duration")
  func taskSleepFor() async throws {
    let start = Swift.ContinuousClock.now
    try await Task.sleep(for: CompatDuration.milliseconds(15))
    #expect(Swift.ContinuousClock.now - start >= .milliseconds(15))
  }

  @Test("Task.sleep(for:) with zero or negative durations returns promptly")
  func taskSleepNonPositive() async throws {
    let start = Swift.ContinuousClock.now
    try await Task.sleep(for: CompatDuration.zero)
    try await Task.sleep(for: CompatDuration.seconds(-5))
    try await Task.sleep(for: CompatDuration(nanosecondsValue: .min))
    #expect(Swift.ContinuousClock.now - start < .milliseconds(500))
  }

  @Test("clock sleep(for:) sleeps at least the duration")
  func clockSleepFor() async throws {
    let start = Swift.ContinuousClock.now
    try await CompatContinuousClock().sleep(for: .milliseconds(10))
    try await CompatSuspendingClock().sleep(for: .milliseconds(10), tolerance: .milliseconds(1))
    #expect(Swift.ContinuousClock.now - start >= .milliseconds(20))
  }

  @Test("sleep(until:) waits for the deadline on both clocks")
  func sleepUntil() async throws {
    let continuousDeadline = CompatContinuousClock.now + .milliseconds(15)
    try await Task.sleep(until: continuousDeadline)
    #expect(CompatContinuousClock.now >= continuousDeadline)

    let explicitClock = CompatContinuousClock.now + .milliseconds(5)
    try await Task.sleep(until: explicitClock, tolerance: .milliseconds(1), clock: CompatContinuousClock())
    #expect(CompatContinuousClock.now >= explicitClock)

    let suspendingDeadline = CompatSuspendingClock.now + .milliseconds(15)
    try await Task.sleep(until: suspendingDeadline, clock: CompatSuspendingClock())
    #expect(CompatSuspendingClock.now >= suspendingDeadline)

    let direct = CompatSuspendingClock.now + .milliseconds(5)
    try await CompatSuspendingClock().sleep(until: direct)
    #expect(CompatSuspendingClock.now >= direct)
  }

  @Test("sleep(until:) a past deadline returns promptly")
  func sleepUntilPast() async throws {
    let start = Swift.ContinuousClock.now
    try await Task.sleep(until: CompatContinuousClock.now - .seconds(10))
    try await Task.sleep(until: CompatSuspendingClock.now - .seconds(10), clock: CompatSuspendingClock())
    #expect(Swift.ContinuousClock.now - start < .milliseconds(500))
  }

  @Test("Task.sleep(for:) throws CancellationError when cancelled mid-sleep")
  func taskSleepCancellation() async {
    let start = Swift.ContinuousClock.now
    let task = Task {
      try await Task.sleep(for: CompatDuration.seconds(30))
    }
    try? await Task.sleep(nanoseconds: 5_000_000)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Swift.ContinuousClock.now - start < .seconds(5))
  }

  @Test("Task.sleep(for:) in an already-cancelled task throws immediately")
  func taskSleepPreCancelled() async {
    let start = Swift.ContinuousClock.now
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await Task.sleep(for: CompatDuration.seconds(30))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Swift.ContinuousClock.now - start < .seconds(5))
  }

  @Test("clock sleeps honour cancellation")
  func clockSleepCancellation() async {
    let start = Swift.ContinuousClock.now
    let tasks = [
      Task { try await CompatContinuousClock().sleep(for: .seconds(30)) },
      Task { try await CompatSuspendingClock().sleep(for: .seconds(30)) },
      Task { try await Task.sleep(until: CompatContinuousClock.now + .seconds(30)) },
      Task { try await Task.sleep(until: CompatSuspendingClock.now + .seconds(30), clock: CompatSuspendingClock()) },
    ]
    try? await Task.sleep(nanoseconds: 5_000_000)
    for task in tasks { task.cancel() }
    for task in tasks {
      await #expect(throws: CancellationError.self) { try await task.value }
    }
    #expect(Swift.ContinuousClock.now - start < .seconds(5))
  }
}

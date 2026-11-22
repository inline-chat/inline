import Dispatch
import Foundation
@testable import InlineCompat
import Testing

private enum BoomError: Error, Equatable {
  case boom(Int)
}

private struct Point: Equatable, Sendable {
  var x: Int
  var y: Int
}

@Suite("Mutex")
struct MutexTests {
  @Test("withLock reads, mutates and returns a result")
  func basics() {
    let mutex = Mutex(10)
    #expect(mutex.withLock { $0 } == 10)
    let doubled = mutex.withLock { value -> Int in
      value *= 2
      return value
    }
    #expect(doubled == 20)
    #expect(mutex.withLock { $0 } == 20)
    // Result type independent of Value.
    #expect(mutex.withLock { "v\($0)" } == "v20")
  }

  @Test("concurrent increments from many tasks are exact")
  func concurrentTasks() async {
    let mutex = Mutex(0)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 64 {
        group.addTask {
          for _ in 0 ..< 1_000 { mutex.withLock { $0 += 1 } }
        }
      }
    }
    #expect(mutex.withLock { $0 } == 64_000)
  }

  @Test("concurrent increments from many threads are exact")
  func concurrentThreads() {
    let mutex = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      for _ in 0 ..< 10_000 { mutex.withLock { $0 += 1 } }
    }
    #expect(mutex.withLock { $0 } == 160_000)
  }

  @Test("concurrent read-modify-write of a compound value stays consistent")
  func compoundInvariant() {
    // x + y is always 0 when every update moves one unit from y to x under the lock.
    let mutex = Mutex(Point(x: 0, y: 0))
    let violations = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 8) { index in
      for _ in 0 ..< 5_000 {
        if index.isMultiple(of: 2) {
          mutex.withLock { point in
            point.x += 1
            point.y -= 1
          }
        } else {
          let sum = mutex.withLock { $0.x + $0.y }
          if sum != 0 { violations.withLock { $0 += 1 } }
        }
      }
    }
    #expect(violations.withLock { $0 } == 0)
    #expect(mutex.withLock { $0 } == Point(x: 20_000, y: -20_000))
  }

  @Test("withLockIfAvailable returns nil while another thread holds the lock")
  func tryLockWhileHeld() {
    let mutex = Mutex(1)
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let bodyRuns = Mutex(0)

    Thread {
      mutex.withLock { value in
        held.signal()
        release.wait()
        value = 2
      }
      finished.signal()
    }.start()

    held.wait()
    let whileHeld = mutex.withLockIfAvailable { value -> Int in
      bodyRuns.withLock { $0 += 1 }
      return value
    }
    #expect(whileHeld == nil)
    #expect(bodyRuns.withLock { $0 } == 0)

    release.signal()
    finished.wait()
    let afterRelease = mutex.withLockIfAvailable { value -> Int in
      value += 1
      return value
    }
    #expect(afterRelease == 3)
    #expect(mutex.withLock { $0 } == 3)
  }

  @Test("withLockIfAvailable takes the free lock and can mutate")
  func tryLockFree() {
    let mutex = Mutex([1, 2])
    let count = mutex.withLockIfAvailable { values -> Int in
      values.append(3)
      return values.count
    }
    #expect(count == 3)
    #expect(mutex.withLock { $0 } == [1, 2, 3])
  }

  @Test("typed errors propagate from withLock, and the lock is released")
  func typedThrowsWithLock() {
    let mutex = Mutex(0)
    #expect(throws: BoomError.boom(1)) {
      try mutex.withLock { (value: inout Int) throws(BoomError) in
        value = 1
        throw .boom(value)
      }
    }
    // Mutations before the throw are kept, and the lock is free again.
    #expect(mutex.withLockIfAvailable { $0 } == 1)

    // The thrown type is statically BoomError: no casting needed.
    do {
      try mutex.withLock { (_: inout Int) throws(BoomError) in throw .boom(7) }
    } catch {
      let typed: BoomError = error
      #expect(typed == .boom(7))
    }
  }

  @Test("typed errors propagate from withLockIfAvailable, and the lock is released")
  func typedThrowsTryLock() {
    let mutex = Mutex(5)
    do {
      _ = try mutex.withLockIfAvailable { (value: inout Int) throws(BoomError) -> Int in
        throw .boom(value)
      }
      Issue.record("expected a throw")
    } catch {
      let typed: BoomError = error
      #expect(typed == .boom(5))
    }
    #expect(mutex.withLockIfAvailable { $0 } == 5)
  }

  @Test("untyped errors still propagate as any Error")
  func untypedThrows() {
    struct Plain: Error {}
    let mutex = Mutex(0)
    #expect(throws: Plain.self) {
      try mutex.withLock { (_: inout Int) throws in throw Plain() }
    }
    #expect(mutex.withLock { $0 } == 0)
  }

  @Test("stored structs have value semantics")
  func valueSemantics() {
    let mutex = Mutex(Point(x: 1, y: 2))
    let snapshot = mutex.withLock { $0 }
    mutex.withLock { $0.x = 100 }
    #expect(snapshot == Point(x: 1, y: 2))
    #expect(mutex.withLock { $0 } == Point(x: 100, y: 2))

    let arrays = Mutex([1, 2, 3])
    var copy = arrays.withLock { $0 }
    copy.append(4)
    _ = arrays.withLock { $0.removeFirst() }
    #expect(copy == [1, 2, 3, 4])
    #expect(arrays.withLock { $0 } == [2, 3])
  }

  @Test("nested locks on different mutexes")
  func nestedDifferentMutexes() {
    let outer = Mutex(1)
    let inner = Mutex(2)
    let sum = outer.withLock { a in inner.withLock { b in a + b } }
    #expect(sum == 3)
  }

  @Test("a mutex can be shared through a let and released")
  func lifetime() {
    weak var weakBox: Sentinel?
    do {
      let mutex = Mutex(Sentinel())
      weakBox = mutex.withLock { $0 }
      #expect(weakBox != nil)
    }
    #expect(weakBox == nil)
  }
}

@Suite("Atomic")
struct AtomicTests {
  @Test("load and store")
  func loadStore() {
    let atomic = Atomic(1)
    #expect(atomic.load() == 1)
    atomic.store(2)
    #expect(atomic.load(ordering: .relaxed) == 2)
    atomic.store(3, ordering: .releasing)
    #expect(atomic.load(ordering: .acquiring) == 3)
    atomic.store(4, ordering: .relaxed)
    #expect(atomic.load(ordering: .sequentiallyConsistent) == 4)
    atomic.store(5, ordering: .sequentiallyConsistent)
    #expect(atomic.load() == 5)
  }

  @Test("exchange returns the previous value")
  func exchange() {
    let atomic = Atomic("a")
    #expect(atomic.exchange("b") == "a")
    #expect(atomic.exchange("c", ordering: .acquiringAndReleasing) == "b")
    atomic.exchange("d", ordering: .relaxed)
    #expect(atomic.load() == "d")
  }

  @Test("compareExchange succeeds only on a match")
  func compareExchange() {
    let atomic = Atomic(10)
    let miss = atomic.compareExchange(expected: 9, desired: 20)
    #expect(miss.exchanged == false)
    #expect(miss.original == 10)
    #expect(atomic.load() == 10)

    let hit = atomic.compareExchange(expected: 10, desired: 20, ordering: .acquiring)
    #expect(hit.exchanged == true)
    #expect(hit.original == 10)
    #expect(atomic.load() == 20)

    let strings = Atomic<String?>(nil)
    #expect(strings.compareExchange(expected: nil, desired: "x").exchanged)
    #expect(!strings.compareExchange(expected: nil, desired: "y").exchanged)
    #expect(strings.load() == "x")
  }

  @Test("wrappingAdd and wrappingSubtract return old and new values")
  func wrappingArithmetic() {
    let atomic = Atomic(10)
    let add = atomic.wrappingAdd(5)
    #expect(add.oldValue == 10)
    #expect(add.newValue == 15)
    let subtract = atomic.wrappingSubtract(20, ordering: .releasing)
    #expect(subtract.oldValue == 15)
    #expect(subtract.newValue == -5)
    #expect(atomic.load() == -5)
  }

  @Test("wrapping arithmetic wraps instead of trapping")
  func wrapping() {
    let byte = Atomic(UInt8.max)
    #expect(byte.wrappingAdd(1).newValue == 0)
    #expect(byte.wrappingSubtract(1).newValue == UInt8.max)

    let int = Atomic(Int.max)
    #expect(int.wrappingAdd(1).newValue == Int.min)
    #expect(int.wrappingSubtract(1).newValue == Int.max)

    let signed = Atomic(Int8.min)
    #expect(signed.wrappingSubtract(1).newValue == Int8.max)
  }

  @Test("logicalOr")
  func logicalOr() {
    let flag = Atomic(false)
    let first = flag.logicalOr(false)
    #expect(first.oldValue == false && first.newValue == false)
    let second = flag.logicalOr(true, ordering: .relaxed)
    #expect(second.oldValue == false && second.newValue == true)
    let third = flag.logicalOr(false)
    #expect(third.oldValue == true && third.newValue == true)
    #expect(flag.load())
  }

  @Test("concurrent wrappingAdd from tasks gives the exact total")
  func concurrentAddTasks() async {
    let counter = Atomic(0)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 32 {
        group.addTask {
          for _ in 0 ..< 1_000 { counter.wrappingAdd(1, ordering: .relaxed) }
        }
      }
    }
    #expect(counter.load() == 32_000)
  }

  @Test("concurrent add and subtract from threads cancel out")
  func concurrentAddSubtractThreads() {
    let counter = Atomic(Int64(0))
    DispatchQueue.concurrentPerform(iterations: 16) { index in
      for _ in 0 ..< 5_000 {
        if index.isMultiple(of: 2) { counter.wrappingAdd(3) } else { counter.wrappingSubtract(3) }
      }
    }
    #expect(counter.load() == 0)
  }

  @Test("compareExchange loops never lose an update")
  func casLoop() {
    let counter = Atomic(0)
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      for _ in 0 ..< 2_000 {
        var current = counter.load()
        while true {
          let result = counter.compareExchange(expected: current, desired: current + 1)
          if result.exchanged { break }
          current = result.original
        }
      }
    }
    #expect(counter.load() == 16_000)
  }

  @Test("exchange and logicalOr let exactly one racer win")
  func exactlyOneWinner() {
    let claimed = Atomic(false)
    let winners = Atomic(0)
    let flag = Atomic(false)
    let orWinners = Atomic(0)
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      if claimed.exchange(true) == false { winners.wrappingAdd(1) }
      if flag.logicalOr(true).oldValue == false { orWinners.wrappingAdd(1) }
    }
    #expect(winners.load() == 1)
    #expect(orWinners.load() == 1)
  }
}

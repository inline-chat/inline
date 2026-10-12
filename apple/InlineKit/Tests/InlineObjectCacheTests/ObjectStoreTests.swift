import Foundation
import Synchronization
import Testing

@testable import InlineObjectCache

/// A dictionary standing in for a database. IDs below 100 are kind 0, the rest kind 1.
final class FakeSource: ObjectSource, Sendable {
  private struct State {
    var data: [Int: String] = [:]
    var syncReads: [[Int]] = []
    var asyncReads: [[Int]] = []
    var heldRead: CheckedContinuation<Void, Never>?
    var holdNextRead = false
  }

  private let state = Mutex(State())

  init(_ data: [Int: String]) {
    state.withLock { $0.data = data }
  }

  func set(_ id: Int, _ value: String?) {
    state.withLock { $0.data[id] = value }
  }

  var syncReads: [[Int]] { state.withLock { $0.syncReads } }
  var asyncReads: [[Int]] { state.withLock { $0.asyncReads } }

  /// The next async read takes its snapshot immediately but does not return until `releaseRead`.
  func holdNextRead() {
    state.withLock { $0.holdNextRead = true }
  }

  var isHoldingRead: Bool { state.withLock { $0.heldRead != nil } }

  func releaseRead() {
    state.withLock { state in
      state.heldRead?.resume()
      state.heldRead = nil
    }
  }

  func kind(of id: Int) -> Int { id < 100 ? 0 : 1 }

  func readNow(_ ids: [Int]) throws -> [Int: String] {
    state.withLock { state in
      state.syncReads.append(ids.sorted())
      return state.data.filter { ids.contains($0.key) }
    }
  }

  func read(_ ids: [Int]) async throws -> [Int: String] {
    let (snapshot, hold) = state.withLock { state in
      state.asyncReads.append(ids.sorted())
      let hold = state.holdNextRead
      state.holdNextRead = false
      return (state.data.filter { ids.contains($0.key) }, hold)
    }
    if hold {
      await withCheckedContinuation { continuation in
        state.withLock { $0.heldRead = continuation }
      }
    }
    return snapshot
  }
}

@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
  for _ in 0 ..< 400 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

@Suite("Object store")
@MainActor
struct ObjectStoreTests {
  private func makeStore(
    _ data: [Int: String], tracked: Int = 100, memory: Int = 1_000
  ) -> (ObjectStore<FakeSource>, FakeSource) {
    let source = FakeSource(data)
    let store = ObjectStore(source: source, limits: .init(tracked: { _ in tracked }, memory: memory))
    return (store, source)
  }

  @Test("get reads unloaded IDs once in one batch, then answers from memory")
  func getReadsOnce() {
    let (store, source) = makeStore([1: "a", 2: "b"])
    #expect(store.cached([1, 2]).state(of: 1) == .unloaded)
    #expect(source.syncReads.isEmpty)

    let snapshot = store.get([1, 2, 3])
    #expect(snapshot.record(1) == "a")
    #expect(snapshot.record(2) == "b")
    #expect(snapshot.state(of: 2) == .fresh)
    #expect(snapshot.state(of: 3) == .missing)
    #expect(source.syncReads == [[1, 2, 3]])

    #expect(store.get([1, 3]).record(1) == "a")
    #expect(store.cached([3]).state(of: 3) == .missing)
    #expect(source.syncReads.count == 1)
    #expect(source.asyncReads.isEmpty)
  }

  @Test("load and warm never read synchronously")
  func loadAndWarmAreAsync() async {
    let (store, source) = makeStore([1: "a", 2: "b"])
    #expect(await store.load([1]).record(1) == "a")
    store.warm([2])
    #expect(store.cached([2]).state(of: 2) == .unloaded)
    #expect(await eventually { store.cached([2]).record(2) == "b" })
    #expect(source.syncReads.isEmpty)
    // Loading something already fresh costs nothing.
    #expect(await store.load([1, 2]).record(2) == "b")
    #expect(source.asyncReads == [[1], [2]])
  }

  @Test("a noted write re-reads that kind's records in one batch and announces only real changes")
  func writeRefreshesKind() async {
    let (store, source) = makeStore([1: "a", 2: "b", 100: "x"])
    _ = store.get([1, 2, 100])
    var announced: [Set<Int>] = []
    let subscription = store.changes.sink { announced.append($0) }
    defer { subscription.cancel() }

    source.set(1, "a2")
    store.noteWrite(0)
    #expect(store.cached([1]).state(of: 1) == .stale)
    #expect(store.cached([100]).state(of: 100) == .fresh)
    #expect(await eventually { store.cached([1]).record(1) == "a2" })
    #expect(store.cached([2]).state(of: 2) == .fresh)
    #expect(source.asyncReads == [[1, 2]])
    #expect(announced == [[1]])
  }

  @Test("records beyond the tracked limit stay stale until used")
  func untrackedStayStaleUntilUsed() async {
    let (store, source) = makeStore([1: "a", 2: "b", 3: "c"], tracked: 2)
    _ = store.get([1, 2, 3])
    _ = store.cached([2, 3])
    for id in 1 ... 3 { source.set(id, "new\(id)") }
    store.noteWrite(0)
    #expect(await eventually { store.peek(3) == "new3" && store.peek(2) == "new2" })
    #expect(store.peek(1) == "a")

    let stale = store.get([1])
    #expect(stale.state(of: 1) == .stale)
    #expect(stale.record(1) == "a")
    #expect(await eventually { store.cached([1]).record(1) == "new1" })
    #expect(source.syncReads.count == 1)
  }

  @Test("an older read never replaces a newer one")
  func olderReadLoses() async {
    let (store, source) = makeStore([1: "old"])
    source.holdNextRead()
    let slow = Task { await store.load([1]) }
    #expect(await eventually { source.isHoldingRead })

    source.set(1, "new")
    #expect(store.get([1]).record(1) == "new")
    source.releaseRead()
    _ = await slow.value
    #expect(store.cached([1]).record(1) == "new")
  }

  @Test("a read that straddles a write is stored stale and read again")
  func straddlingReadIsRepeated() async {
    let (store, source) = makeStore([1: "old"])
    source.holdNextRead()
    let slow = Task { await store.load([1]) }
    #expect(await eventually { source.isHoldingRead })

    source.set(1, "new")
    store.noteWrite(0)
    source.releaseRead()
    #expect(await slow.value.record(1) == "old")
    #expect(await eventually { store.cached([1]).record(1) == "new" })
    #expect(await eventually { store.cached([1]).state(of: 1) == .fresh })
  }

  @Test("unseen writes re-check every record, including kinds not yet in memory")
  func unseenWritesRecheckEverything() async {
    let (store, source) = makeStore([1: "a", 100: "x"], tracked: 0)
    _ = store.get([1])
    source.holdNextRead()
    let slow = Task { await store.load([100]) }
    #expect(await eventually { source.isHoldingRead })

    source.set(1, "a2")
    source.set(100, "x2")
    store.noteUnseenWrites()
    source.releaseRead()
    _ = await slow.value
    #expect(await eventually { store.cached([1]).record(1) == "a2" })
    #expect(await eventually { store.cached([100]).record(100) == "x2" })
  }

  @Test("reset forgets everything and discards reads in flight")
  func resetDiscardsInFlightReads() async {
    let (store, source) = makeStore([1: "a", 2: "b"])
    _ = store.get([1])
    source.holdNextRead()
    let slow = Task { await store.load([2]) }
    #expect(await eventually { source.isHoldingRead })

    var announced: Set<Int> = []
    let subscription = store.changes.sink { announced.formUnion($0) }
    defer { subscription.cancel() }
    store.reset()
    source.releaseRead()
    _ = await slow.value
    #expect(announced == [1])
    #expect(store.count == 0)
    #expect(store.cached([1, 2]).state(of: 2) == .unloaded)
  }

  @Test("memory is bounded by evicting the least recently used records")
  func memoryIsBounded() {
    let data = Dictionary(uniqueKeysWithValues: (1 ... 12).map { ($0, "v\($0)") })
    let (store, _) = makeStore(data, memory: 4)
    for id in 1 ... 12 {
      _ = store.get([id])
    }
    #expect(store.count <= 4)
    #expect(store.peek(12) == "v12")
    #expect(store.peek(1) == nil)
  }
}

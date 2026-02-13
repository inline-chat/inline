import Foundation
import Testing

@testable import InlineKit

@Suite("Target Messages Fetcher")
struct TargetMessagesFetcherTests {
  @Test("does not fetch when all message ids are already cached")
  func doesNotFetchWhenNoMissingIds() async {
    let recorder = FetchRecorder()
    let fetcher = TargetMessagesFetcher(
      resolveMissingIds: { _, _ in [] },
      fetchMessages: { _, messageIds in
        await recorder.record(messageIds)
      }
    )

    await fetcher.ensureCached(peer: .thread(id: 10), chatId: 10, messageIds: [1, 2, 3])

    #expect(await recorder.count() == 0)
  }

  @Test("filters invalid ids before resolving cache misses")
  func filtersInvalidIdsBeforeLookup() async {
    let resolverProbe = MissingIDsProbe()
    let recorder = FetchRecorder()
    let fetcher = TargetMessagesFetcher(
      resolveMissingIds: { chatId, messageIds in
        await resolverProbe.record(chatId: chatId, messageIds: messageIds)
        return messageIds
      },
      fetchMessages: { _, messageIds in
        await recorder.record(messageIds)
      }
    )

    await fetcher.ensureCached(peer: .thread(id: 11), chatId: 11, messageIds: [0, -1, 4, 4, 5])

    #expect(await resolverProbe.lastChatId() == 11)
    #expect(await resolverProbe.lastIDs() == Set([4, 5]))

    let didFetch = await waitForCondition(timeout: .seconds(2)) {
      await recorder.count() == 1
    }
    #expect(didFetch)

    let batches = await recorder.batchesAsSets()
    #expect(batches == [Set([4, 5])])
  }

  @Test("dedupes overlapping ids while first fetch is in flight")
  func dedupesOverlappingInFlightIDs() async {
    let recorder = FetchRecorder()
    let gate = FirstFetchGate()
    let fetcher = TargetMessagesFetcher(
      resolveMissingIds: { _, messageIds in messageIds },
      fetchMessages: { _, messageIds in
        await recorder.record(messageIds)
        await gate.blockFirstFetchIfNeeded()
      }
    )

    let first = Task {
      await fetcher.ensureCached(peer: .thread(id: 12), chatId: 12, messageIds: [1, 2])
    }

    await gate.waitForFirstFetchBlocked()

    let second = Task {
      await fetcher.ensureCached(peer: .thread(id: 12), chatId: 12, messageIds: [2, 3])
    }

    await gate.releaseFirstFetch()

    await first.value
    await second.value

    let fetchedTwice = await waitForCondition(timeout: .seconds(2)) {
      await recorder.count() == 2
    }
    #expect(fetchedTwice)

    let batches = await recorder.batchesAsSets()
    #expect(batches.count == 2)
    #expect(batches[0] == Set([1, 2]))
    #expect(batches[1] == Set([3]))
  }

  @Test("getMessages transaction encodes peer and message ids")
  func getMessagesTransactionInput() {
    let transaction = GetMessagesTransaction(peer: .thread(id: 44), messageIds: [7, 8])

    guard case let .getMessages(input)? = transaction.input(from: transaction.context) else {
      Issue.record("Expected getMessages input")
      return
    }

    #expect(input.messageIds == [7, 8])

    switch input.peerID.type {
      case let .chat(chat):
        #expect(chat.chatID == 44)
      default:
        Issue.record("Expected chat peer input")
    }
  }
}

private actor MissingIDsProbe {
  private var chatId: Int64?
  private var ids: Set<Int64> = []

  func record(chatId: Int64, messageIds: Set<Int64>) {
    self.chatId = chatId
    ids = messageIds
  }

  func lastChatId() -> Int64? {
    chatId
  }

  func lastIDs() -> Set<Int64> {
    ids
  }
}

private actor FetchRecorder {
  private var items: [[Int64]] = []

  func record(_ messageIds: [Int64]) {
    items.append(messageIds)
  }

  func count() -> Int {
    items.count
  }

  func batches() -> [[Int64]] {
    items
  }

  func batchesAsSets() -> [Set<Int64>] {
    items.map(Set.init)
  }
}

private actor FirstFetchGate {
  private var firstFetchBlocked = false
  private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func blockFirstFetchIfNeeded() async {
    guard !firstFetchBlocked else { return }
    firstFetchBlocked = true

    let waiters = blockedWaiters
    blockedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitForFirstFetchBlocked() async {
    if firstFetchBlocked {
      return
    }

    await withCheckedContinuation { continuation in
      blockedWaiters.append(continuation)
    }
  }

  func releaseFirstFetch() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private func waitForCondition(
  timeout: Duration,
  pollInterval: Duration = .milliseconds(10),
  _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while clock.now < deadline {
    if await condition() {
      return true
    }
    try? await Task.sleep(for: pollInterval)
  }

  return await condition()
}

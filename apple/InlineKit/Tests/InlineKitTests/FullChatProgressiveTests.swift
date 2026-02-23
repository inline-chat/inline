import Foundation
import Testing

@testable import InlineKit

@Suite("MessagesProgressiveViewModel Ordering Tests")
struct MessagesProgressiveViewModelOrderingTests {
  @Test("stable sort uses date + globalId tie-break")
  func testStableSortTieBreak() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let message3 = makeFullMessage(messageId: 3, globalId: 30, date: date)
    let message1 = makeFullMessage(messageId: 1, globalId: 10, date: date)
    let message2 = makeFullMessage(messageId: 2, globalId: 20, date: date)

    let batch = [message3, message1, message2]

    let sorted = await MainActor.run {
      MessagesProgressiveViewModel.stableSortedMessages(batch, reversed: false)
    }
    #expect(sorted.map { $0.message.globalId } == [10, 20, 30])

    let reversed = await MainActor.run {
      MessagesProgressiveViewModel.stableSortedMessages(batch, reversed: true)
    }
    #expect(reversed.map { $0.message.globalId } == [30, 20, 10])
  }

  @Test("cursor dedupe removes only overlapping messages at cursor boundary")
  func testCursorBoundaryDedupe() async throws {
    let cursor = Date(timeIntervalSince1970: 1_700_000_000)
    let older = Date(timeIntervalSince1970: 1_699_999_900)
    let newer = Date(timeIntervalSince1970: 1_700_000_100)

    let existingAtCursor = makeFullMessage(messageId: 10, globalId: 110, date: cursor)
    let existingElsewhere = makeFullMessage(messageId: 20, globalId: 220, date: older)
    let overlappingAtCursor = makeFullMessage(messageId: 10, globalId: 110, date: cursor)
    let newAtCursor = makeFullMessage(messageId: 30, globalId: 330, date: cursor)
    let newAtOlderDate = makeFullMessage(messageId: 40, globalId: 440, date: older)
    let newAtNewerDate = makeFullMessage(messageId: 50, globalId: 550, date: newer)

    let deduped = await MainActor.run {
      MessagesProgressiveViewModel.batchDedupedAtCursor(
        [overlappingAtCursor, newAtCursor, newAtOlderDate, newAtNewerDate],
        existingMessages: [existingAtCursor, existingElsewhere],
        cursor: cursor
      )
    }

    #expect(deduped.map(\.id) == [330, 440, 550])
  }

  @Test("merge helper keeps deterministic prepend and append ordering")
  func testMergeMessagesDeterministicOrder() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let existing = [
      makeFullMessage(messageId: 1, globalId: 101, date: date),
      makeFullMessage(messageId: 2, globalId: 102, date: date.addingTimeInterval(1)),
    ]
    let additional = [
      makeFullMessage(messageId: 3, globalId: 103, date: date.addingTimeInterval(-2)),
      makeFullMessage(messageId: 4, globalId: 104, date: date.addingTimeInterval(-1)),
    ]

    let prepended = await MainActor.run {
      MessagesProgressiveViewModel.mergedMessages(
        existing: existing,
        additionalBatch: additional,
        prepend: true
      )
    }
    #expect(prepended.map(\.id) == [103, 104, 101, 102])

    let appended = await MainActor.run {
      MessagesProgressiveViewModel.mergedMessages(
        existing: existing,
        additionalBatch: additional,
        prepend: false
      )
    }
    #expect(appended.map(\.id) == [101, 102, 103, 104])
  }

  @Test("gap range merge combines overlapping and adjacent ranges")
  func testGapRangeMerge() async throws {
    let merged = await MainActor.run {
      MessagesProgressiveViewModel.mergedGapRanges([
        .init(startMessageId: 10, endMessageId: 20),
        .init(startMessageId: 21, endMessageId: 30),
        .init(startMessageId: 40, endMessageId: 50),
        .init(startMessageId: 45, endMessageId: 60),
      ])
    }

    #expect(merged.count == 2)
    #expect(merged[0].startMessageId == 10)
    #expect(merged[0].endMessageId == 30)
    #expect(merged[1].startMessageId == 40)
    #expect(merged[1].endMessageId == 60)
  }
}

private func makeFullMessage(messageId: Int64, globalId: Int64?, date: Date) -> FullMessage {
  var message = Message(
    messageId: messageId,
    fromId: 1,
    date: date,
    text: "hi",
    peerUserId: nil,
    peerThreadId: 1,
    chatId: 1
  )
  message.globalId = globalId

  return FullMessage(
    senderInfo: nil,
    message: message,
    reactions: [],
    repliedToMessage: nil,
    attachments: []
  )
}

import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("MessagesProgressiveViewModel Ordering Tests")
struct MessagesProgressiveViewModelOrderingTests {
  @Test("stable sort uses persisted message ID before local insertion ID")
  func testStableSortTieBreak() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let message3 = makeFullMessage(messageId: 3, globalId: 10, date: date)
    let message1 = makeFullMessage(messageId: 1, globalId: 30, date: date)
    let message2 = makeFullMessage(messageId: 2, globalId: 20, date: date)

    let batch = [message3, message1, message2]

    let sorted = await MainActor.run {
      MessagesProgressiveViewModel.stableSortedMessages(batch, reversed: false)
    }
    #expect(sorted.map { $0.message.messageId } == [1, 2, 3])

    let reversed = await MainActor.run {
      MessagesProgressiveViewModel.stableSortedMessages(batch, reversed: true)
    }
    #expect(reversed.map { $0.message.messageId } == [3, 2, 1])
  }

  @Test("optimistic message keeps local insertion order within the same second")
  func testOptimisticMessageUsesLocalInsertionOrder() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let persisted = makeFullMessage(messageId: 20, globalId: 100, date: date)
    let optimistic = makeFullMessage(messageId: -1_234, globalId: 200, date: date)

    let reversed = await MainActor.run {
      MessagesProgressiveViewModel.stableSortedMessages([persisted, optimistic], reversed: true)
    }

    #expect(reversed.map { $0.message.messageId } == [-1_234, 20])
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

  @Test("batch dedupe removes already loaded messages regardless of cursor date")
  func testBatchDedupeRemovesAnyLoadedMessage() async throws {
    let cursor = Date(timeIntervalSince1970: 1_700_000_000)
    let older = Date(timeIntervalSince1970: 1_699_999_900)

    let existingAtCursor = makeFullMessage(messageId: 10, globalId: 110, date: cursor)
    let existingOlder = makeFullMessage(messageId: 20, globalId: 220, date: older)
    let duplicateAtCursor = makeFullMessage(messageId: 10, globalId: 110, date: cursor)
    let duplicateOlder = makeFullMessage(messageId: 20, globalId: 220, date: older)
    let newOlder = makeFullMessage(messageId: 30, globalId: 330, date: older)

    let deduped = await MainActor.run {
      MessagesProgressiveViewModel.batchDeduped(
        [duplicateAtCursor, duplicateOlder, newOlder],
        existingByID: [
          existingAtCursor.id: existingAtCursor,
          existingOlder.id: existingOlder,
        ]
      )
    }

    #expect(deduped.map(\.id) == [330])
  }

  @Test("loaded window bounds use date and message id cursor order")
  func testLoadedWindowBoundsUseDateAndMessageId() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let newest = makeFullMessage(messageId: 30, globalId: 300, date: date.addingTimeInterval(10))
    let sameDateHigherId = makeFullMessage(messageId: 20, globalId: 200, date: date)
    let sameDateLowerId = makeFullMessage(messageId: 10, globalId: 100, date: date)

    let bounds = await MainActor.run {
      MessagesProgressiveViewModel.loadedWindowBounds(for: [sameDateHigherId, newest, sameDateLowerId])
    }

    #expect(bounds?.oldestMessageId == 10)
    #expect(bounds?.oldestDate == date)
    #expect(bounds?.newestMessageId == 30)
    #expect(bounds?.newestDate == date.addingTimeInterval(10))
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

  @Test("persisted holes project unknown adjacency and uncertified edges")
  func testHistoryCoverageProjection() {
    let messages = [10, 20, 30, 40].map {
      makeFullMessage(
        messageId: Int64($0),
        globalId: Int64($0),
        date: Date(timeIntervalSince1970: Double($0))
      )
    }
    let projection = MessageHistoryCoverageProjection(
      messages: messages,
      holes: [
        MessageHistoryHole(chatId: 1, lowerId: 1, upperId: 9),
        MessageHistoryHole(chatId: 1, lowerId: 21, upperId: 29),
        MessageHistoryHole(
          chatId: 1,
          lowerId: 41,
          upperId: MessageHistoryHole.positiveMessageIDMax
        ),
      ],
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )

    #expect(projection.unknownAdjacencyBoundaries.count == 1)
    #expect(projection.unknownAdjacencyBoundaries.first?.lowerMessageID == 20)
    #expect(projection.unknownAdjacencyBoundaries.first?.upperMessageID == 30)
    #expect(projection.isCertifiedContinuation(between: 10, and: 20))
    #expect(!projection.isCertifiedContinuation(between: 20, and: 30))
    #expect(!projection.hasCertifiedOlderEdge)
    #expect(!projection.hasCertifiedNewerEdge)
    #expect(!projection.isAtCertifiedLiveEnd)
  }

  @Test("candidate edges are certified without claiming the live end")
  func testHistoryCoverageCandidateEdges() {
    let messages = [20, 30].map {
      makeFullMessage(
        messageId: Int64($0),
        globalId: Int64($0),
        date: Date(timeIntervalSince1970: Double($0))
      )
    }
    let projection = MessageHistoryCoverageProjection(
      messages: messages,
      holes: [
        MessageHistoryHole(chatId: 1, lowerId: 1, upperId: 9),
        MessageHistoryHole(
          chatId: 1,
          lowerId: 41,
          upperId: MessageHistoryHole.positiveMessageIDMax
        ),
      ],
      olderCandidateMessageID: 10,
      newerCandidateMessageID: 40
    )

    #expect(projection.hasCertifiedOlderEdge)
    #expect(projection.hasCertifiedNewerEdge)
    #expect(!projection.isAtCertifiedLiveEnd)
    #expect(projection.unknownAdjacencyBoundaries.isEmpty)
  }

  @Test("a hole-free empty snapshot is a certified live end")
  func testCompleteEmptyHistoryCoverage() {
    let projection = MessageHistoryCoverageProjection(
      messages: [],
      holes: [],
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )

    #expect(projection.hasCertifiedOlderEdge)
    #expect(projection.hasCertifiedNewerEdge)
    #expect(projection.isAtCertifiedLiveEnd)
  }

  @Test("progressive coverage snapshot reads the persisted hole authority")
  func testPersistedHistoryCoverageProjection() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    let messages = [10, 20].map {
      makeFullMessage(
        messageId: Int64($0),
        globalId: Int64($0),
        date: Date(timeIntervalSince1970: Double($0))
      )
    }

    try queue.write { (db: Database) throws in
      try User(id: 1, email: "coverage@example.com", firstName: "Coverage").insert(db)
      try Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Coverage",
        spaceId: nil,
        lastMsgId: 20
      ).insert(db)
      for fullMessage in messages {
        var message = fullMessage.message
        try message.saveMessage(db)
      }
      try MessageHistoryCoverageStore.subtract(db, chatId: 1, lowerId: 1, upperId: 10)
      try MessageHistoryCoverageStore.subtract(
        db,
        chatId: 1,
        lowerId: 20,
        upperId: MessageHistoryHole.positiveMessageIDMax
      )

      let metadata = try MessagesProgressiveViewModel.loadedWindowMetadata(
        db,
        peer: .thread(id: 1),
        messages: messages
      )
      let descendingMetadata = try MessagesProgressiveViewModel.loadedWindowMetadata(
        db,
        peer: .thread(id: 1),
        messages: Array(messages.reversed())
      )
      let optimistic = makeFullMessage(
        messageId: -1,
        globalId: nil,
        date: Date(timeIntervalSince1970: 1_000)
      )
      let optimisticMetadata = try MessagesProgressiveViewModel.loadedWindowMetadata(
        db,
        peer: .thread(id: 1),
        messages: [optimistic] + messages
      )
      let projection = metadata.historyCoverage
      #expect(metadata == descendingMetadata)
      #expect(metadata == optimisticMetadata)
      #expect(metadata.oldestLoadedMessageId == 10)
      #expect(metadata.newestLoadedMessageId == 20)
      #expect(!metadata.canLoadOlderFromLocal)
      #expect(!metadata.canLoadNewerFromLocal)
      #expect(!projection.isCertifiedContinuation(between: 10, and: 20))
      #expect(projection.hasCertifiedOlderEdge)
      #expect(projection.hasCertifiedNewerEdge)
      #expect(projection.isAtCertifiedLiveEnd)
    }
  }

  @Test("prepared first frame installs canonical coverage and pagination metadata")
  @MainActor
  func testPreparedFirstFrameUsesCanonicalMetadata() async {
    let peer = Peer.user(id: 9_003)
    let message = makeFullMessage(
      messageId: 30,
      globalId: 30,
      date: Date(timeIntervalSince1970: 30),
      peerUserId: peer.id
    )
    let coverage = MessageHistoryCoverageProjection(
      messages: [message],
      holes: [],
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )
    let metadata = MessagesProgressiveViewModel.LoadedWindowMetadata(
      messages: [message],
      holes: []
    )
    let viewModel = MessagesProgressiveViewModel(
      peer: peer,
      initialState: .init(messages: [message], loadedWindowMetadata: metadata)
    )

    #expect(viewModel.oldestLoadedMessageId == 30)
    #expect(viewModel.newestLoadedMessageId == 30)
    #expect(viewModel.historyCoverage == coverage)
    #expect(viewModel.historyCoverage.isAtCertifiedLiveEnd)
    #expect(!viewModel.needsNewerHistoryRepair)
    let didLoadRedundantNewerBatch = await viewModel.loadBatchAsync(
      at: .newer,
      allowUnavailableLocal: true
    )
    #expect(!didLoadRedundantNewerBatch)
  }

  @Test("deleted numeric anchor loads certified neighbors without requiring an exact row")
  func testDeletedAnchorLoadsCertifiedNeighborWindow() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { (db: Database) throws in
      try User(id: 1, email: "coordinate@example.com", firstName: "Coordinate").insert(db)
      try Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Coordinate",
        spaceId: nil,
        lastMsgId: 61
      ).insert(db)
      for id in [59, 61] as [Int64] {
        var message = Message(
          messageId: id,
          fromId: 1,
          date: Date(timeIntervalSince1970: Double(id)),
          text: "Message \(id)",
          peerUserId: nil,
          peerThreadId: 1,
          chatId: 1
        )
        try message.saveMessage(db)
      }

      #expect(try MessagesProgressiveViewModel.localWindowAroundCoordinate(
        db,
        peer: .thread(id: 1),
        messageID: 60,
        limit: 60
      ) == nil)

      try MessageHistoryCoverageStore.subtract(db, chatId: 1, lowerId: 59, upperId: 61)
      let window = try MessagesProgressiveViewModel.localWindowAroundCoordinate(
        db,
        peer: .thread(id: 1),
        messageID: 60,
        limit: 60
      )
      #expect(window?.map(\.message.messageId) == [59, 61])
    }
  }

  @Test("latest repair merge preserves the prepared island and adds the live tail")
  func testLatestRepairMergePreservesPreparedWindow() {
    let prepared = [40, 50].map {
      makeFullMessage(
        messageId: Int64($0),
        globalId: Int64($0),
        date: Date(timeIntervalSince1970: Double($0))
      )
    }
    let latest = [90, 100].map {
      makeFullMessage(
        messageId: Int64($0),
        globalId: Int64($0),
        date: Date(timeIntervalSince1970: Double($0))
      )
    }

    let ascending = MessagesProgressiveViewModel.mergingLatestMessages(
      existing: prepared,
      latest: latest,
      reversed: false
    )
    let descending = MessagesProgressiveViewModel.mergingLatestMessages(
      existing: Array(prepared.reversed()),
      latest: Array(latest.reversed()),
      reversed: true
    )

    #expect(ascending.map(\.message.messageId) == [40, 50, 90, 100])
    #expect(descending.map(\.message.messageId) == [100, 90, 50, 40])
  }

  @Test("publisher reload defers its database snapshot off the synchronous MainActor publication")
  @MainActor
  func testPublisherReloadIsAsynchronous() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let publisher = MessagesPublisher(database: database)
    try await queue.write { (db: Database) throws in
      try User(id: 1, email: "reload@example.com", firstName: "Reload").insert(db)
      try Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Reload",
        spaceId: nil,
        lastMsgId: 1
      ).insert(db)
      var message = Message(
        messageId: 1,
        fromId: 1,
        date: Date(timeIntervalSince1970: 1),
        text: "Reloaded",
        peerUserId: nil,
        peerThreadId: 1,
        chatId: 1
      )
      try message.saveMessage(db)
      try MessageHistoryCoverageStore.subtract(
        db,
        chatId: 1,
        lowerId: 1,
        upperId: MessageHistoryHole.positiveMessageIDMax
      )
    }

    let viewModel = MessagesProgressiveViewModel(
      peer: .thread(id: 1),
      initialState: .init(
        messages: [],
        loadedWindowMetadata: .init(messages: [], holes: [])
      ),
      database: database,
      publisher: publisher,
      currentUserId: 1
    )
    var didReload = false
    viewModel.observe { change in
      if case .reload = change { didReload = true }
    }

    publisher.messagesReload(peer: .thread(id: 1), animated: false)
    #expect(!didReload)
    #expect(viewModel.messages.isEmpty)

    for _ in 0 ..< 100 where !didReload {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(didReload)
    #expect(viewModel.messages.map(\.message.messageId) == [1])
    #expect(viewModel.historyCoverage.isAtCertifiedLiveEnd)
  }

  @Test("stale generation or window fingerprint cannot overwrite newer metadata")
  @MainActor
  func testStaleWindowMetadataIsRejected() {
    let peer = Peer.user(id: 9_004)
    let first = makeFullMessage(
      messageId: 40,
      globalId: 40,
      date: Date(timeIntervalSince1970: 40),
      peerUserId: peer.id
    )
    let second = makeFullMessage(
      messageId: 50,
      globalId: 50,
      date: Date(timeIntervalSince1970: 50),
      peerUserId: peer.id
    )
    let initialCoverage = MessageHistoryCoverageProjection(
      messages: [first],
      holes: [],
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )
    let viewModel = MessagesProgressiveViewModel(
      peer: peer,
      initialState: .init(
        messages: [first],
        loadedWindowMetadata: .init(messages: [first], holes: [])
      )
    )

    let staleFingerprintRequest = viewModel.beginLoadedWindowMetadataRequest()
    viewModel.messages = [first, second]
    let staleMetadata = testLoadedWindowMetadata(messages: [first])
    #expect(!viewModel.applyLoadedWindowMetadata(staleMetadata, for: staleFingerprintRequest))
    #expect(viewModel.historyCoverage == initialCoverage)

    let staleGenerationRequest = viewModel.beginLoadedWindowMetadataRequest()
    let currentRequest = viewModel.beginLoadedWindowMetadataRequest()
    let newerMetadata = testLoadedWindowMetadata(messages: [first, second])
    #expect(!viewModel.applyLoadedWindowMetadata(newerMetadata, for: staleGenerationRequest))

    let currentCoverage = MessageHistoryCoverageProjection(
      messages: [first, second],
      holes: [],
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )
    let currentMetadata = MessagesProgressiveViewModel.LoadedWindowMetadata(
      messages: [first, second],
      holes: []
    )
    #expect(viewModel.applyLoadedWindowMetadata(currentMetadata, for: currentRequest))
    #expect(viewModel.newestLoadedMessageId == 50)
    #expect(viewModel.historyCoverage == currentCoverage)
  }

  @Test("reversed add reports inserted head index")
  @MainActor
  func testReversedAddReportsHeadIndex() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let peer = Peer.user(id: 9_002)
    let existing = makeFullMessage(messageId: 20, globalId: 200, date: date, peerUserId: peer.id)
    let added = makeFullMessage(messageId: -1_234, globalId: nil, date: date, peerUserId: peer.id)
    let initialState = MessagesProgressiveViewModel.InitialState(
      messages: [existing],
      loadedWindowMetadata: testLoadedWindowMetadata(messages: [existing])
    )
    let viewModel = MessagesProgressiveViewModel(
      peer: peer,
      reversed: true,
      initialState: initialState
    )

    var update: MessagesProgressiveViewModel.MessagesChangeSet?
    viewModel.observe { update = $0 }
    MessagesPublisher.shared.publisher.send(.add(.init(messages: [added], peer: peer)))

    guard case let .added(messages, indexSet)? = update else {
      Issue.record("Expected added change set")
      return
    }

    #expect(messages.map(\.id) == [added.id])
    #expect(indexSet == [0])
    #expect(viewModel.messages.map(\.id) == [added.id, existing.id])
  }
}

private func testLoadedWindowMetadata(
  messages: [FullMessage] = []
) -> MessagesProgressiveViewModel.LoadedWindowMetadata {
  .init(
    messages: messages,
    holes: [
      MessageHistoryHole(
        chatId: 0,
        lowerId: 1,
        upperId: MessageHistoryHole.positiveMessageIDMax
      ),
    ]
  )
}

private func makeFullMessage(
  messageId: Int64,
  globalId: Int64?,
  date: Date,
  peerUserId: Int64? = nil
) -> FullMessage {
  var message = Message(
    messageId: messageId,
    fromId: 1,
    date: date,
    text: "hi",
    peerUserId: peerUserId,
    peerThreadId: peerUserId == nil ? 1 : nil,
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

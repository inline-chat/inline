import Foundation
import Testing

@testable import InlineKit

@Suite("MessagesSectionedViewModel Ordering Tests")
struct MessagesSectionedViewModelOrderingTests {
  @Test("sectioned projection exposes the immutable history coverage snapshot")
  @MainActor
  func projectsHistoryCoverage() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let peer = Peer.user(id: 9_000)
    let older = makeSectionTestFullMessage(
      messageId: 10,
      globalId: 10,
      date: date,
      peerUserId: peer.id
    )
    let newer = makeSectionTestFullMessage(
      messageId: 20,
      globalId: 20,
      date: date.addingTimeInterval(1),
      peerUserId: peer.id
    )
    let coverage = MessageHistoryCoverageProjection(
      messages: [older, newer],
      holes: [MessageHistoryHole(chatId: 1, lowerId: 11, upperId: 19)],
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )
    let viewModel = MessagesSectionedViewModel(
      peer: peer,
      reversed: true,
      initialState: .init(
        messages: [newer, older],
        loadedWindowMetadata: .init(
          messages: [newer, older],
          holes: [MessageHistoryHole(chatId: 1, lowerId: 11, upperId: 19)]
        )
      )
    )

    #expect(viewModel.historyCoverage == coverage)
    #expect(!viewModel.isCertifiedHistoryContinuation(between: 10, and: 20))
  }

  @Test("collapse boundary is applied before initial sections and can be cleared")
  @MainActor
  func collapseBoundaryProjectsVisibleMessages() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let peer = Peer.user(id: 9_002)
    let old = makeSectionTestFullMessage(messageId: 1, globalId: 1, date: date, peerUserId: peer.id)
    let boundary = makeSectionTestFullMessage(messageId: 2, globalId: 2, date: date, peerUserId: peer.id)
    let visible = makeSectionTestFullMessage(messageId: 3, globalId: 3, date: date, peerUserId: peer.id)
    let pending = makeSectionTestFullMessage(
      messageId: -4,
      globalId: nil,
      date: date,
      peerUserId: peer.id,
      status: .sending
    )
    let initialState = MessagesProgressiveViewModel.InitialState(
      messages: [old, boundary, visible, pending],
      loadedWindowMetadata: testSectionLoadedWindowMetadata(messages: [old, boundary, visible, pending])
    )

    let viewModel = MessagesSectionedViewModel(
      peer: peer,
      reversed: true,
      initialState: initialState,
      collapsedMaxId: 2
    )

    #expect(Set(viewModel.messages.map(\.message.messageId)) == Set([-4, 3]))
    #expect(Set(viewModel.sections.flatMap(\.messages).map(\.message.messageId)) == Set([-4, 3]))
    #expect(viewModel.highestPositiveMessageId == 3)

    var update: MessagesSectionedViewModel.SectionedMessagesChangeSet?
    viewModel.observe { update = $0 }
    viewModel.setCollapsedMaxId(nil)

    guard case .reload(animated: false)? = update else {
      Issue.record("Expected an unanimated reload after clearing the boundary")
      return
    }
    #expect(Set(viewModel.messages.map(\.message.messageId)) == Set([-4, 1, 2, 3]))
  }

  @Test("section sort keeps persisted same-second messages in server order")
  func testSectionSortUsesStableTieBreakers() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let message3 = makeSectionTestFullMessage(messageId: 3, globalId: 10, date: date)
    let message1 = makeSectionTestFullMessage(messageId: 1, globalId: 30, date: date)
    let message2 = makeSectionTestFullMessage(messageId: 2, globalId: 20, date: date)

    let sorted = await MainActor.run {
      MessagesSectionedViewModel.sortMessagesForSection([message3, message1, message2])
    }

    #expect(sorted.map { $0.message.messageId } == [3, 2, 1])
  }

  @Test("section sort falls back to messageId when globalId is missing")
  func testSectionSortFallsBackToMessageId() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let message3 = makeSectionTestFullMessage(messageId: 3, globalId: nil, date: date)
    let message1 = makeSectionTestFullMessage(messageId: 1, globalId: nil, date: date)
    let message2 = makeSectionTestFullMessage(messageId: 2, globalId: nil, date: date)

    let sorted = await MainActor.run {
      MessagesSectionedViewModel.sortMessagesForSection([message1, message2, message3])
    }

    #expect(sorted.map { $0.message.messageId } == [3, 2, 1])
  }

  @Test("head adds use messagesAdded even when sort key is older")
  @MainActor
  func testHeadAddUsesIncrementalChangeSet() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let peer = Peer.user(id: 9_001)
    let existing = makeSectionTestFullMessage(
      messageId: 20,
      globalId: 200,
      date: date,
      peerUserId: peer.id
    )
    let optimistic = makeSectionTestFullMessage(
      messageId: -1_234,
      globalId: nil,
      date: date,
      peerUserId: peer.id,
      status: .sending
    )
    let initialState = MessagesProgressiveViewModel.InitialState(
      messages: [existing],
      loadedWindowMetadata: testSectionLoadedWindowMetadata(messages: [existing])
    )
    let viewModel = MessagesSectionedViewModel(
      peer: peer,
      reversed: true,
      initialState: initialState
    )

    var update: MessagesSectionedViewModel.SectionedMessagesChangeSet?
    viewModel.observe { update = $0 }
    MessagesPublisher.shared.publisher.send(.add(.init(messages: [optimistic], peer: peer)))

    guard case let .messagesAdded(sectionIndex, messageIds)? = update else {
      Issue.record("Expected messagesAdded for optimistic head insert")
      return
    }

    #expect(sectionIndex == 0)
    #expect(messageIds == [optimistic.id])
    #expect(viewModel.sections.first?.messages.map(\.id) == [optimistic.id, existing.id])
  }

  @Test("first message uses the incremental add path")
  @MainActor
  func testFirstMessageUsesIncrementalChangeSet() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let peer = Peer.user(id: 9_003)
    let firstMessage = makeSectionTestFullMessage(
      messageId: -1,
      globalId: nil,
      date: date,
      peerUserId: peer.id,
      status: .sending
    )
    let viewModel = MessagesSectionedViewModel(
      peer: peer,
      reversed: true,
      initialState: .init(
        messages: [],
        loadedWindowMetadata: testSectionLoadedWindowMetadata()
      )
    )

    var update: MessagesSectionedViewModel.SectionedMessagesChangeSet?
    viewModel.observe { update = $0 }
    MessagesPublisher.shared.publisher.send(.add(.init(messages: [firstMessage], peer: peer)))

    guard case let .messagesAdded(sectionIndex, messageIds)? = update else {
      Issue.record("Expected messagesAdded for the first message")
      return
    }

    #expect(sectionIndex == 0)
    #expect(messageIds == [firstMessage.id])
    #expect(viewModel.sections.count == 1)
  }

  @Test("first message of a newer day uses the incremental add path")
  @MainActor
  func testFirstMessageOfNewerDayUsesIncrementalChangeSet() {
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newDate = Calendar.current.date(byAdding: .day, value: 1, to: oldDate)!
    let peer = Peer.user(id: 9_004)
    let existing = makeSectionTestFullMessage(
      messageId: 20,
      globalId: 20,
      date: oldDate,
      peerUserId: peer.id
    )
    let firstMessageOfNewDay = makeSectionTestFullMessage(
      messageId: -2,
      globalId: nil,
      date: newDate,
      peerUserId: peer.id,
      status: .sending
    )
    let viewModel = MessagesSectionedViewModel(
      peer: peer,
      reversed: true,
      initialState: .init(
        messages: [existing],
        loadedWindowMetadata: testSectionLoadedWindowMetadata(messages: [existing])
      )
    )

    var update: MessagesSectionedViewModel.SectionedMessagesChangeSet?
    viewModel.observe { update = $0 }
    MessagesPublisher.shared.publisher.send(.add(.init(messages: [firstMessageOfNewDay], peer: peer)))

    guard case let .messagesAdded(sectionIndex, messageIds)? = update else {
      Issue.record("Expected messagesAdded for the first message of a newer day")
      return
    }

    #expect(sectionIndex == 0)
    #expect(messageIds == [firstMessageOfNewDay.id])
    #expect(viewModel.sections.count == 2)
    #expect(viewModel.sections.first?.messages.map(\.id) == [firstMessageOfNewDay.id])
  }

  @Test("first visible message after clear uses the incremental add path")
  @MainActor
  func testFirstMessageAfterClearUsesIncrementalChangeSet() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let peer = Peer.user(id: 9_005)
    let clearedMessage = makeSectionTestFullMessage(
      messageId: 10,
      globalId: 10,
      date: date,
      peerUserId: peer.id
    )
    let pendingMessage = makeSectionTestFullMessage(
      messageId: -3,
      globalId: nil,
      date: date,
      peerUserId: peer.id,
      status: .sending
    )
    let viewModel = MessagesSectionedViewModel(
      peer: peer,
      reversed: true,
      initialState: .init(
        messages: [clearedMessage],
        loadedWindowMetadata: testSectionLoadedWindowMetadata(messages: [clearedMessage])
      ),
      collapsedMaxId: clearedMessage.message.messageId
    )

    #expect(viewModel.sections.isEmpty)

    var update: MessagesSectionedViewModel.SectionedMessagesChangeSet?
    viewModel.observe { update = $0 }
    MessagesPublisher.shared.publisher.send(.add(.init(messages: [pendingMessage], peer: peer)))

    guard case let .messagesAdded(sectionIndex, messageIds)? = update else {
      Issue.record("Expected messagesAdded for the first visible message after clear")
      return
    }

    #expect(sectionIndex == 0)
    #expect(messageIds == [pendingMessage.id])
    #expect(viewModel.sections.first?.messages.map(\.id) == [pendingMessage.id])

    update = nil
    MessagesPublisher.shared.publisher.send(.update(.init(
      message: pendingMessage,
      animated: true,
      peer: peer
    )))

    guard case let .messagesUpdated(updatedSectionIndex, updatedMessageIds, animated)? = update else {
      Issue.record("Expected messagesUpdated after the post-clear optimistic add")
      return
    }

    #expect(updatedSectionIndex == 0)
    #expect(updatedMessageIds == [pendingMessage.id])
    #expect(animated == true)
  }
}

private func testSectionLoadedWindowMetadata(
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

private func makeSectionTestFullMessage(
  messageId: Int64,
  globalId: Int64?,
  date: Date,
  peerUserId: Int64? = nil,
  status: MessageSendingStatus? = nil
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
  message.status = status

  return FullMessage(
    senderInfo: nil,
    message: message,
    reactions: [],
    repliedToMessage: nil,
    attachments: []
  )
}

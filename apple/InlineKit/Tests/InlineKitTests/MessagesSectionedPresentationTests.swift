import Foundation
import Testing

@testable import InlineKit

@Suite("MessagesSectionedViewModel Presentation")
struct MessagesSectionedPresentationTests {
  @Test("presentation sections append a reply-thread anchor to an existing same-day section")
  func presentationSectionsAppendReplyThreadAnchorToSameDaySection() async throws {
    let day = Date(timeIntervalSince1970: 1_710_000_000)
    let newestReply = makePresentationTestMessage(messageId: 3, chatId: 41, date: day.addingTimeInterval(3_600))
    let olderReply = makePresentationTestMessage(messageId: 2, chatId: 41, date: day.addingTimeInterval(1_800))
    let anchor = makePresentationTestMessage(messageId: 99, chatId: 7, date: day)

    let replySections = [
      MessagesSectionedViewModel.RawSection(
        date: day,
        dayString: "Today",
        messages: [newestReply, olderReply]
      )
    ]

    let sections = await MainActor.run {
      MessagesSectionedViewModel.buildPresentationSections(
        from: replySections,
        replyThreadAnchorMessage: anchor
      )
    }

    #expect(sections.count == 1)
    #expect(
      sections[0].items == [
        .message(chatId: 41, messageId: 3),
        .message(chatId: 41, messageId: 2),
        .replyThreadAnchor(chatId: 7, messageId: 99),
      ]
    )
  }

  @Test("presentation sections create an anchor-only section when there are no replies yet")
  func presentationSectionsCreateAnchorOnlySection() async throws {
    let anchorDay = Date(timeIntervalSince1970: 1_710_000_000)
    let anchor = makePresentationTestMessage(messageId: 99, chatId: 7, date: anchorDay)

    let sections = await MainActor.run {
      MessagesSectionedViewModel.buildPresentationSections(
        from: [],
        replyThreadAnchorMessage: anchor
      )
    }

    #expect(sections.count == 1)
    #expect(sections[0].date == Calendar.current.startOfDay(for: anchorDay))
    #expect(sections[0].items == [.replyThreadAnchor(chatId: 7, messageId: 99)])
  }

  @Test("presentation row items flatten sections with day separators and anchor rows")
  func presentationRowItemsFlattenSectionsWithSeparatorsAndAnchorRows() async throws {
    let newestDay = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_710_000_000))
    let olderDay = Calendar.current.date(byAdding: .day, value: -1, to: newestDay)!

    let rowItems = await MainActor.run {
      MessagesSectionedViewModel.buildRowItems(from: [
        MessagesSectionedViewModel.MessageSection(
          date: newestDay,
          dayString: "Today",
          items: [
            .message(chatId: 41, messageId: 3),
            .replyThreadAnchor(chatId: 7, messageId: 99),
          ]
        ),
        MessagesSectionedViewModel.MessageSection(
          date: olderDay,
          dayString: "Yesterday",
          items: [
            .message(chatId: 41, messageId: 2),
          ]
        ),
      ])
    }

    #expect(
      rowItems == [
        .daySeparator(dayStart: newestDay),
        .item(.message(chatId: 41, messageId: 3)),
        .item(.replyThreadAnchor(chatId: 7, messageId: 99)),
        .daySeparator(dayStart: olderDay),
        .item(.message(chatId: 41, messageId: 2)),
      ]
    )
  }
}

private func makePresentationTestMessage(messageId: Int64, chatId: Int64, date: Date) -> FullMessage {
  let message = Message(
    messageId: messageId,
    fromId: 1,
    date: date,
    text: "message-\(messageId)",
    peerUserId: nil,
    peerThreadId: chatId,
    chatId: chatId
  )

  return FullMessage(
    senderInfo: nil,
    message: message,
    reactions: [],
    repliedToMessage: nil,
    attachments: []
  )
}

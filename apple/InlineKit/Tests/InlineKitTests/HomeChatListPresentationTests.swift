import Foundation
@testable import InlineKit
import Testing

@Suite("Home chat-list presentation")
struct HomeChatListPresentationTests {
  @Test("Narrow snapshot query executes against the current schema")
  func queryMatchesSchema() throws {
    let database = AppDatabase.empty()
    let snapshots = try database.reader.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true
      )
    }

    #expect(snapshots.isEmpty)
  }

  @Test("Inbox contains open chats only and keeps pinned chats first")
  func inboxMembershipAndOrdering() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, pinned: false, activity: date(day: 3)),
      item(2, open: false, pinned: true, activity: date(day: 4)),
      item(3, open: true, pinned: true, activity: date(day: 1)),
    ], sort: .lastUpdated, calendar: calendar)

    #expect(presentation.inbox.map(\.peer) == [.thread(id: 3), .thread(id: 1)])
    #expect(presentation.closedPinned.map(\.peer) == [.thread(id: 2)])
  }

  @Test("All Chats includes Inbox and separates only closed pinned chats")
  func allChatsMembership() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, pinned: false, activity: date(day: 3)),
      item(2, open: false, pinned: true, activity: date(day: 4)),
      item(3, open: false, pinned: false, activity: date(day: 2)),
      item(4, open: true, pinned: true, activity: date(day: 1)),
    ], sort: .lastUpdated, calendar: calendar)

    #expect(Set(presentation.allChats.map(\.peer)) == Set([
      .thread(id: 1), .thread(id: 2), .thread(id: 3), .thread(id: 4),
    ]))
    #expect(presentation.closedPinned.map(\.peer) == [.thread(id: 2)])
    #expect(presentation.allChatSections.flatMap(\.items).map(\.peer) == [
      .thread(id: 1), .thread(id: 3), .thread(id: 4),
    ])
  }

  @Test("Archived and hidden chats do not leak into active surfaces")
  func archivedVisibility() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, archived: true, activity: date(day: 3)),
      item(2, open: true, hidden: true, activity: date(day: 2)),
      item(3, open: true, activity: date(day: 1)),
    ], sort: .lastUpdated, calendar: calendar)

    #expect(presentation.inbox.map(\.peer) == [.thread(id: 3)])
    #expect(presentation.allChats.map(\.peer) == [.thread(id: 3)])
    #expect(presentation.archived.map(\.peer) == [.thread(id: 1)])
  }

  @Test("Opened-time sorting also drives day-section grouping")
  func openedTimeSections() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 4), opened: date(day: 1)),
      item(2, open: true, activity: date(day: 2), opened: date(day: 3)),
    ], sort: .recentlyOpened, calendar: calendar)

    #expect(presentation.allChatSections.map(\.id) == [date(day: 3), date(day: 1)])
    #expect(presentation.allChatSections.flatMap(\.items).map(\.peer) == [
      .thread(id: 2), .thread(id: 1),
    ])
  }

  @Test("Inbox unread badge excludes closed chats")
  func inboxUnreadCount() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, unreadCount: 2),
      item(2, open: false, unreadCount: 5),
      item(3, open: true, unreadMark: true),
    ], sort: .lastUpdated, calendar: calendar)

    #expect(presentation.inboxUnreadCount == 2)
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func date(day: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 8, day: day))!
  }

  private func item(
    _ id: Int64,
    open: Bool = false,
    pinned: Bool = false,
    archived: Bool = false,
    hidden: Bool = false,
    unreadCount: Int = 0,
    unreadMark: Bool = false,
    activity: Date? = nil,
    opened: Date? = nil
  ) -> ChatListItemSnapshot {
    ChatListItemSnapshot(
      peer: .thread(id: id),
      chatID: id,
      title: "Chat \(id)",
      unreadCount: unreadCount,
      unreadMark: unreadMark,
      isOpen: open,
      isPinned: pinned,
      isChatListHidden: hidden,
      isArchived: archived,
      lastUpdatedAt: activity,
      openedDate: opened
    )
  }
}

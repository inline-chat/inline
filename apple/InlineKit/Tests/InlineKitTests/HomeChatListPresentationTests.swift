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
    #expect(presentation.allChats.map(\.peer).contains(.thread(id: 2)))
  }

  @Test("All Chats includes Inbox and keeps closed pinned chats in activity order")
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
    #expect(presentation.allChatSections.flatMap(\.items).map(\.peer) == [
      .thread(id: 2), .thread(id: 1), .thread(id: 3), .thread(id: 4),
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

  @Test("Row timestamps only describe activity from today")
  func todayOnlyRowTimestamps() {
    let now = calendar.date(from: DateComponents(
      year: 2026,
      month: 8,
      day: 4,
      hour: 14,
      minute: 30
    ))!
    let justNow = now.addingTimeInterval(-30)
    let earlierToday = now.addingTimeInterval(-3_600)
    let yesterday = now.addingTimeInterval(-86_400)

    #expect(ChatListDateFormatter.rowTitle(for: justNow, now: now, calendar: calendar) == "just now")
    #expect(ChatListDateFormatter.rowTitle(for: earlierToday, now: now, calendar: calendar) != nil)
    #expect(ChatListDateFormatter.rowTitle(for: yesterday, now: now, calendar: calendar) == nil)
  }

  @Test("Structural diff ignores content-only changes and detects membership moves")
  func structuralDiff() {
    let original = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 3)),
      item(2, open: false, activity: date(day: 2)),
    ], sort: .lastUpdated, calendar: calendar)
    let contentOnly = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 3), title: "Renamed"),
      item(2, open: false, activity: date(day: 2)),
    ], sort: .lastUpdated, calendar: calendar)
    let moved = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 3)),
      item(2, open: true, activity: date(day: 2)),
    ], sort: .lastUpdated, calendar: calendar)

    #expect(contentOnly.structuralLocationChangeCount(from: original) == 0)
    #expect(moved.structuralLocationChangeCount(from: original) == 1)
  }

  @Test("Pinning one Inbox chat remains a small animated reorder")
  func pinnedReorderDiff() {
    let original = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 4)),
      item(2, open: true, activity: date(day: 3)),
      item(3, open: true, activity: date(day: 2)),
      item(4, open: true, activity: date(day: 1)),
    ], sort: .lastUpdated, calendar: calendar)
    let pinned = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 4)),
      item(2, open: true, activity: date(day: 3)),
      item(3, open: true, pinned: true, activity: date(day: 2)),
      item(4, open: true, activity: date(day: 1)),
    ], sort: .lastUpdated, calendar: calendar)

    #expect(pinned.inbox.map(\.peer) == [
      .thread(id: 3), .thread(id: 1), .thread(id: 2), .thread(id: 4),
    ])
    #expect(pinned.structuralLocationChangeCount(from: original) == 3)
  }

  @Test("Production-scale projection keeps stable identity and surface membership")
  func productionScaleProjection() {
    let itemCount = 5_000
    let snapshots = (1 ... itemCount).map { index in
      item(
        Int64(index),
        open: index.isMultiple(of: 3),
        pinned: index.isMultiple(of: 97),
        archived: index.isMultiple(of: 31),
        hidden: index.isMultiple(of: 47),
        unreadCount: index.isMultiple(of: 11) ? 1 : 0,
        activity: Date(timeIntervalSince1970: TimeInterval(itemCount - index))
      )
    }

    let presentation = ChatListPresentation.make(
      from: snapshots,
      sort: .lastUpdated,
      calendar: calendar
    )
    let expectedVisible = snapshots.filter(\.isVisibleInHome)
    let expectedInbox = expectedVisible.filter(\.isOpen)
    let allPeers = presentation.allChats.map(\.peer)
    let pinnedPrefixIsValid = presentation.inbox
      .prefix { $0.isPinned }
      .allSatisfy { $0.isPinned }
    let unpinnedSuffixIsValid = presentation.inbox
      .drop { $0.isPinned }
      .allSatisfy { !$0.isPinned }
    let allChatsAreActivityOrdered = presentation.allChats.elementsEqual(
      presentation.allChats.sorted {
        ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast)
      }
    )

    #expect(presentation.allChatCount == expectedVisible.count)
    #expect(presentation.inbox.count == expectedInbox.count)
    #expect(Set(allPeers).count == allPeers.count)
    #expect(pinnedPrefixIsValid)
    #expect(unpinnedSuffixIsValid)
    #expect(allChatsAreActivityOrdered)
    #expect(presentation.structuralLocationChangeCount(from: presentation) == 0)
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
    opened: Date? = nil,
    title: String? = nil
  ) -> ChatListItemSnapshot {
    ChatListItemSnapshot(
      peer: .thread(id: id),
      chatID: id,
      title: title ?? "Chat \(id)",
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

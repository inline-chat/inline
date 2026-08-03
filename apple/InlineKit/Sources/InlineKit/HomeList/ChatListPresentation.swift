import Foundation

public struct ChatListDaySection: Identifiable, Equatable, Sendable {
  public let id: Date
  public let items: [ChatListItemSnapshot]

  public init(id: Date, items: [ChatListItemSnapshot]) {
    self.id = id
    self.items = items
  }
}

/// Every render-ready Home surface prepared from one database snapshot.
///
/// Keeping Inbox and All Chats in one immutable value means switching tabs never
/// performs filtering, sorting, grouping, or a database read on the main actor.
public struct ChatListPresentation: Equatable, Sendable {
  public static let empty = Self(
    inbox: [],
    closedPinned: [],
    allChatSections: [],
    archived: [],
    inboxUnreadCount: 0
  )

  public let inbox: [ChatListItemSnapshot]
  public let closedPinned: [ChatListItemSnapshot]
  public let allChatSections: [ChatListDaySection]
  public let archived: [ChatListItemSnapshot]
  public let inboxUnreadCount: Int

  public init(
    inbox: [ChatListItemSnapshot],
    closedPinned: [ChatListItemSnapshot],
    allChatSections: [ChatListDaySection],
    archived: [ChatListItemSnapshot],
    inboxUnreadCount: Int
  ) {
    self.inbox = inbox
    self.closedPinned = closedPinned
    self.allChatSections = allChatSections
    self.archived = archived
    self.inboxUnreadCount = inboxUnreadCount
  }

  public static func make(
    from snapshots: [ChatListItemSnapshot],
    sort: ChatListSort,
    calendar: Calendar = .autoupdatingCurrent
  ) -> Self {
    let visible = snapshots.filter(\.isVisibleInHome)
    let inbox = visible
      .filter(\.isOpen)
      .sorted { inboxOrdered($0, before: $1, sort: sort) }
    let closedPinned = visible
      .filter { !$0.isOpen && $0.isPinned }
      .sorted(by: pinnedOrdered)
    let timeline = visible
      .filter { $0.isOpen || !$0.isPinned }
      .sorted { timelineOrdered($0, before: $1, sort: sort) }
    let archived = snapshots
      .filter { !$0.isChatListHidden && $0.isArchived }
      .sorted { timelineOrdered($0, before: $1, sort: sort) }

    return Self(
      inbox: inbox,
      closedPinned: closedPinned,
      allChatSections: daySections(from: timeline, sort: sort, calendar: calendar),
      archived: archived,
      inboxUnreadCount: inbox.lazy.filter(\.isUnread).count
    )
  }

  public var allChats: [ChatListItemSnapshot] {
    closedPinned + allChatSections.flatMap(\.items)
  }

  private static func daySections(
    from items: [ChatListItemSnapshot],
    sort: ChatListSort,
    calendar: Calendar
  ) -> [ChatListDaySection] {
    var grouped: [(day: Date, items: [ChatListItemSnapshot])] = []

    for item in items {
      let day = calendar.startOfDay(for: sortDate(for: item, sort: sort))
      if grouped.last?.day == day {
        grouped[grouped.count - 1].items.append(item)
      } else {
        grouped.append((day: day, items: [item]))
      }
    }

    return grouped.map { ChatListDaySection(id: $0.day, items: $0.items) }
  }

  private static func inboxOrdered(
    _ lhs: ChatListItemSnapshot,
    before rhs: ChatListItemSnapshot,
    sort: ChatListSort
  ) -> Bool {
    if lhs.isPinned != rhs.isPinned {
      return lhs.isPinned
    }
    if lhs.isPinned, let order = compareOptionalOrder(lhs.pinnedOrder, rhs.pinnedOrder) {
      return order
    }
    return timelineOrdered(lhs, before: rhs, sort: sort)
  }

  private static func pinnedOrdered(
    _ lhs: ChatListItemSnapshot,
    _ rhs: ChatListItemSnapshot
  ) -> Bool {
    if let order = compareOptionalOrder(lhs.pinnedOrder, rhs.pinnedOrder) {
      return order
    }
    return timelineOrdered(lhs, before: rhs, sort: .lastUpdated)
  }

  private static func timelineOrdered(
    _ lhs: ChatListItemSnapshot,
    before rhs: ChatListItemSnapshot,
    sort: ChatListSort
  ) -> Bool {
    let lhsDate = sortDate(for: lhs, sort: sort)
    let rhsDate = sortDate(for: rhs, sort: sort)
    if lhsDate != rhsDate {
      return lhsDate > rhsDate
    }
    return lhs.peer.toString() < rhs.peer.toString()
  }

  private static func sortDate(
    for snapshot: ChatListItemSnapshot,
    sort: ChatListSort
  ) -> Date {
    switch sort {
    case .lastUpdated:
      snapshot.lastUpdatedAt ?? .distantPast
    case .recentlyOpened:
      snapshot.openedDate ?? snapshot.lastUpdatedAt ?? .distantPast
    }
  }

  private static func compareOptionalOrder(_ lhs: String?, _ rhs: String?) -> Bool? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?) where lhs != rhs:
      lhs < rhs
    case (_?, nil):
      true
    case (nil, _?):
      false
    default:
      nil
    }
  }
}

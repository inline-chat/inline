import Foundation

public struct ChatListDaySection: Identifiable, Equatable, Sendable {
  public let id: Date
  public let items: [ChatListItemSnapshot]

  public init(id: Date, items: [ChatListItemSnapshot]) {
    self.id = id
    self.items = items
  }
}

public enum ChatListTimelinePeriod: Hashable, Sendable {
  case day(Date)
  case month(year: Int, month: Int)
  case year(Int)

  public static func classify(
    _ date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> Self {
    let day = calendar.startOfDay(for: date)
    let today = calendar.startOfDay(for: now)
    let daysAgo = calendar.dateComponents([.day], from: day, to: today).day
    if let daysAgo, daysAgo < 7 {
      return .day(day)
    }

    let year = calendar.component(.year, from: day)
    if year == calendar.component(.year, from: today) {
      return .month(year: year, month: calendar.component(.month, from: day))
    }
    return .year(year)
  }
}

public struct ChatListTimelineSection: Identifiable, Equatable, Sendable {
  public let id: ChatListTimelinePeriod
  public let items: [ChatListItemSnapshot]

  public init(id: ChatListTimelinePeriod, items: [ChatListItemSnapshot]) {
    self.id = id
    self.items = items
  }
}

/// Every render-ready Home surface prepared from one database snapshot.
///
/// Keeping Inbox, All Chats, and Archived Chats in one immutable value means
/// switching surfaces never performs filtering, sorting, grouping, or a database
/// read on the main actor.
public struct ChatListPresentation: Equatable, Sendable {
  public static let empty = Self(
    inbox: [],
    allChatsPinned: [],
    allChatSections: [],
    archived: [],
    inboxUnreadCount: 0
  )

  public let inbox: [ChatListItemSnapshot]
  public let inboxPinned: [ChatListItemSnapshot]
  public let inboxUnpinned: [ChatListItemSnapshot]
  public let allChatsPinned: [ChatListItemSnapshot]
  public let allChatSections: [ChatListTimelineSection]
  public let archived: [ChatListItemSnapshot]
  public let archivedSections: [ChatListDaySection]
  public let inboxUnreadCount: Int

  public init(
    inbox: [ChatListItemSnapshot],
    allChatsPinned: [ChatListItemSnapshot],
    allChatSections: [ChatListTimelineSection],
    archived: [ChatListItemSnapshot],
    inboxUnreadCount: Int,
    calendar: Calendar = .autoupdatingCurrent
  ) {
    self.inbox = inbox
    self.inboxPinned = inbox.filter(\.isPinned)
    self.inboxUnpinned = inbox.filter { !$0.isPinned }
    self.allChatsPinned = allChatsPinned
    self.allChatSections = allChatSections
    self.archived = archived
    self.archivedSections = Self.daySections(from: archived, calendar: calendar)
    self.inboxUnreadCount = inboxUnreadCount
  }

  public static func make(
    from snapshots: [ChatListItemSnapshot],
    inboxSort: ChatListSort,
    allChatsFilter: ChatListFilter = .all,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> Self {
    let visible = snapshots.filter(\.isVisibleInHome)
    let inbox = snapshots
      .filter(\.isInboxMember)
      .sorted { inboxOrdered($0, before: $1, sort: inboxSort) }
    let timeline = visible
      .filter { allChatsFilter == .all || $0.isUnread }
      .sorted { timelineOrdered($0, before: $1, sort: .lastUpdated) }
    let allChatsPinned = timeline
      .filter(\.isPinned)
      .sorted { lhs, rhs in
        compareOptionalOrder(lhs.pinnedOrder, rhs.pinnedOrder)
          ?? timelineOrdered(lhs, before: rhs, sort: .lastUpdated)
      }
    let allChatsTimeline = timeline.filter { !$0.isPinned }
    let archived = snapshots
      .filter { !$0.isChatListHidden && $0.isArchived }
      .sorted { timelineOrdered($0, before: $1, sort: .lastUpdated) }

    return Self(
      inbox: inbox,
      allChatsPinned: allChatsPinned,
      allChatSections: timelineSections(
        from: allChatsTimeline,
        now: now,
        calendar: calendar
      ),
      archived: archived,
      inboxUnreadCount: inbox.lazy.filter(\.isUnread).count,
      calendar: calendar
    )
  }

  public var allChats: [ChatListItemSnapshot] {
    allChatsPinned + allChatSections.flatMap(\.items)
  }

  public var allChatCount: Int {
    allChatSections.reduce(into: allChatsPinned.count) { count, section in
      count += section.items.count
    }
  }

  /// Counts only identity moves between Home surfaces or positions. Content-only
  /// updates intentionally return zero so they do not trigger list move animations.
  public func structuralLocationChangeCount(from previous: Self) -> Int {
    let oldLocations = previous.locationsByPeer()
    let newLocations = locationsByPeer()
    let peers = Set(oldLocations.keys).union(newLocations.keys)
    return peers.lazy.count { oldLocations[$0] != newLocations[$0] }
  }

  private static func daySections(
    from items: [ChatListItemSnapshot],
    calendar: Calendar
  ) -> [ChatListDaySection] {
    var grouped: [(day: Date, items: [ChatListItemSnapshot])] = []

    for item in items {
      let day = calendar.startOfDay(for: sortDate(for: item, sort: .lastUpdated))
      if grouped.last?.day == day {
        grouped[grouped.count - 1].items.append(item)
      } else {
        grouped.append((day: day, items: [item]))
      }
    }

    return grouped.map { ChatListDaySection(id: $0.day, items: $0.items) }
  }

  private static func timelineSections(
    from items: [ChatListItemSnapshot],
    now: Date,
    calendar: Calendar
  ) -> [ChatListTimelineSection] {
    var grouped: [(period: ChatListTimelinePeriod, items: [ChatListItemSnapshot])] = []

    for item in items {
      let period = ChatListTimelinePeriod.classify(
        sortDate(for: item, sort: .lastUpdated),
        relativeTo: now,
        calendar: calendar
      )
      if grouped.last?.period == period {
        grouped[grouped.count - 1].items.append(item)
      } else {
        grouped.append((period: period, items: [item]))
      }
    }

    return grouped.map { ChatListTimelineSection(id: $0.period, items: $0.items) }
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

  private enum OrderedSectionID: Equatable {
    case inboxPinned
    case inbox
    case allChatsPinned
    case allChats(ChatListTimelinePeriod)
    case archived(Date)
  }

  private struct OrderedPosition: Equatable {
    let predecessor: Peer?
    let sectionID: OrderedSectionID
  }

  private struct Locations: Equatable {
    var inbox: OrderedPosition?
    var allChats: OrderedPosition?
    var archived: OrderedPosition?
  }

  private func locationsByPeer() -> [Peer: Locations] {
    var locations: [Peer: Locations] = [:]
    locations.reserveCapacity(max(inbox.count, allChatCount, archived.count))

    var predecessor: Peer?
    for item in inboxPinned {
      locations[item.peer, default: Locations()].inbox = OrderedPosition(
        predecessor: predecessor,
        sectionID: .inboxPinned
      )
      predecessor = item.peer
    }

    predecessor = nil
    for item in inboxUnpinned {
      locations[item.peer, default: Locations()].inbox = OrderedPosition(
        predecessor: predecessor,
        sectionID: .inbox
      )
      predecessor = item.peer
    }

    predecessor = nil
    for item in allChatsPinned {
      locations[item.peer, default: Locations()].allChats = OrderedPosition(
        predecessor: predecessor,
        sectionID: .allChatsPinned
      )
      predecessor = item.peer
    }

    predecessor = nil
    for section in allChatSections {
      for item in section.items {
        locations[item.peer, default: Locations()].allChats = OrderedPosition(
          predecessor: predecessor,
          sectionID: .allChats(section.id)
        )
        predecessor = item.peer
      }
    }

    predecessor = nil
    for section in archivedSections {
      for item in section.items {
        locations[item.peer, default: Locations()].archived = OrderedPosition(
          predecessor: predecessor,
          sectionID: .archived(section.id)
        )
        predecessor = item.peer
      }
    }
    return locations
  }
}

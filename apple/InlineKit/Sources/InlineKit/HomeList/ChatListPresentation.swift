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
    allChatSections: [],
    archived: [],
    inboxUnreadCount: 0
  )

  public let inbox: [ChatListItemSnapshot]
  public let allChatSections: [ChatListDaySection]
  public let archived: [ChatListItemSnapshot]
  public let inboxUnreadCount: Int

  public init(
    inbox: [ChatListItemSnapshot],
    allChatSections: [ChatListDaySection],
    archived: [ChatListItemSnapshot],
    inboxUnreadCount: Int
  ) {
    self.inbox = inbox
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
    let timeline = visible
      .sorted { timelineOrdered($0, before: $1, sort: sort) }
    let archived = snapshots
      .filter { !$0.isChatListHidden && $0.isArchived }
      .sorted { timelineOrdered($0, before: $1, sort: sort) }

    return Self(
      inbox: inbox,
      allChatSections: daySections(from: timeline, sort: sort, calendar: calendar),
      archived: archived,
      inboxUnreadCount: inbox.lazy.filter(\.isUnread).count
    )
  }

  public var allChats: [ChatListItemSnapshot] {
    allChatSections.flatMap(\.items)
  }

  public var allChatCount: Int {
    allChatSections.reduce(into: 0) { count, section in
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

  private struct OrderedPosition: Equatable {
    let predecessor: Peer?
    let sectionID: Date?
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
    for item in inbox {
      locations[item.peer, default: Locations()].inbox = OrderedPosition(
        predecessor: predecessor,
        sectionID: nil
      )
      predecessor = item.peer
    }

    predecessor = nil
    for section in allChatSections {
      for item in section.items {
        locations[item.peer, default: Locations()].allChats = OrderedPosition(
          predecessor: predecessor,
          sectionID: section.id
        )
        predecessor = item.peer
      }
    }

    predecessor = nil
    for item in archived {
      locations[item.peer, default: Locations()].archived = OrderedPosition(
        predecessor: predecessor,
        sectionID: nil
      )
      predecessor = item.peer
    }
    return locations
  }
}

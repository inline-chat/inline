import Combine
import Foundation
import Logger

/// A view model that bridges MessagesProgressiveViewModel into a presentational,
/// day-sectioned message list with support for synthetic rows such as reply-thread anchors.
@MainActor
public class MessagesSectionedViewModel {
  private static let calendar = Calendar.current

  public enum Item: Hashable, Sendable {
    case message(chatId: Int64, messageId: Int64)
    case replyThreadAnchor(chatId: Int64, messageId: Int64)
  }

  public enum RowItem: Hashable, Sendable {
    case daySeparator(dayStart: Date)
    case item(Item)
  }

  struct RawSection: Sendable {
    let date: Date
    let dayString: String
    var messages: [FullMessage]
  }

  public struct MessageSection: Equatable, Sendable {
    public let date: Date
    public let dayString: String
    public var items: [Item]

    public init(date: Date, dayString: String, items: [Item]) {
      self.date = date
      self.dayString = dayString
      self.items = items
    }
  }

  private struct MessageKey: Hashable {
    let chatId: Int64
    let messageId: Int64
  }

  public private(set) var sections: [MessageSection] = []
  public private(set) var rowItems: [RowItem] = []
  public var messages: [FullMessage] { progressiveViewModel.messages }
  public var messagesByID: [Int64: FullMessage] { progressiveViewModel.messagesByID }
  public var displayedMessages: [FullMessage] {
    rowItems.compactMap(fullMessage(for:))
  }
  public var oldestLoadedMessageId: Int64? { progressiveViewModel.oldestLoadedMessageId }
  public var newestLoadedMessageId: Int64? { progressiveViewModel.newestLoadedMessageId }
  public var canLoadOlderFromLocal: Bool { progressiveViewModel.canLoadOlderFromLocal }
  public var canLoadNewerFromLocal: Bool { progressiveViewModel.canLoadNewerFromLocal }
  public private(set) var replyThreadAnchorMessage: FullMessage?

  private let progressiveViewModel: MessagesProgressiveViewModel
  private let log = Log.scoped("MessagesSectionedViewModel")
  private var callback: ((_ changeSet: SectionedMessagesChangeSet) -> Void)?
  private var rawSections: [RawSection] = []
  private var rawMessagesByKey: [MessageKey: FullMessage] = [:]
  private var rawMessagesByStableID: [Int64: FullMessage] = [:]

  public init(
    peer: Peer,
    reversed: Bool = false,
    initialState: MessagesProgressiveViewModel.InitialState? = nil
  ) {
    progressiveViewModel = MessagesProgressiveViewModel(
      peer: peer,
      reversed: reversed,
      initialState: initialState
    )
    progressiveViewModel.observe { [weak self] update in
      guard let self else { return }
      log.trace("Received progressive update: \(update)")
      if let sectionedUpdate = convertToSectionedChangeSet(from: update) {
        callback?(sectionedUpdate)
      }
    }
    rebuildSections()
  }

  public func observe(_ callback: @escaping (SectionedMessagesChangeSet) -> Void) {
    if self.callback != nil {
      log.warning("Callback already set, re-setting it to a new one will result in undefined behaviour")
    }
    self.callback = callback
  }

  public func setReplyThreadAnchorMessage(_ message: FullMessage?) {
    guard replyThreadAnchorMessage != message else { return }
    replyThreadAnchorMessage = message
    rebuildPresentationSections()
    callback?(.reload(animated: true))
  }

  public func loadBatch(
    at direction: MessagesProgressiveViewModel.MessagesLoadDirection,
    publish: Bool = true
  ) {
    let previousSections = sections
    let previousRawMessagesByKey = rawMessagesByKey

    progressiveViewModel.loadBatch(at: direction, publish: publish)
    rebuildSections()

    let addedMessages = messages.filter { message in
      !previousRawMessagesByKey.keys.contains(Self.messageKey(for: message))
    }

    guard let changeSet = makeAddedChangeSet(
      addedMessages: addedMessages,
      previousSections: previousSections
    ) else {
      return
    }

    if publish {
      callback?(changeSet)
    }
  }

  @discardableResult
  public func loadLocalWindowAroundMessage(messageId: Int64, publish: Bool = true) -> Bool {
    let didLoad = progressiveViewModel.loadLocalWindowAroundMessage(
      messageId: messageId,
      publish: publish
    )

    guard didLoad else { return false }

    rebuildSections()
    if publish {
      callback?(.reload(animated: false))
    }

    return true
  }

  public func setAtBottom(_ atBottom: Bool) {
    progressiveViewModel.setAtBottom(atBottom)
  }

  public func dispose() {
    progressiveViewModel.dispose()
    callback = nil
  }

  private func rebuildSections() {
    let messages = progressiveViewModel.messages
    rawMessagesByKey = Dictionary(uniqueKeysWithValues: messages.map { (Self.messageKey(for: $0), $0) })
    rawMessagesByStableID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    rawSections = groupMessagesByDay(messages)
    rebuildPresentationSections()
  }

  private func rebuildPresentationSections() {
    sections = Self.buildPresentationSections(from: rawSections, replyThreadAnchorMessage: replyThreadAnchorMessage)
    rowItems = Self.buildRowItems(from: sections)
  }

  nonisolated static func sortMessagesForSection(_ messages: [FullMessage]) -> [FullMessage] {
    guard messages.count > 1 else { return messages }

    return messages
      .enumerated()
      .sorted { lhs, rhs in
        let lhsDate = lhs.element.message.date
        let rhsDate = rhs.element.message.date
        if lhsDate != rhsDate {
          return lhsDate > rhsDate
        }

        let lhsGlobalId = lhs.element.message.globalId ?? 0
        let rhsGlobalId = rhs.element.message.globalId ?? 0
        if lhsGlobalId != rhsGlobalId {
          return lhsGlobalId > rhsGlobalId
        }

        let lhsMessageId = lhs.element.message.messageId
        let rhsMessageId = rhs.element.message.messageId
        if lhsMessageId != rhsMessageId {
          return lhsMessageId > rhsMessageId
        }

        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private func groupMessagesByDay(_ messages: [FullMessage]) -> [RawSection] {
    let grouped = Dictionary(grouping: messages) { message in
      Self.calendar.startOfDay(for: message.message.date)
    }

    let sortedKeys = grouped.keys.sorted { $0 > $1 }

    return sortedKeys.map { dayStart in
      let dayMessages = grouped[dayStart] ?? []
      let dayString = Self.formatDateForSection(dayStart)
      let sortedMessages = Self.sortMessagesForSection(dayMessages)

      return RawSection(
        date: dayStart,
        dayString: dayString,
        messages: sortedMessages
      )
    }
  }

  static func buildPresentationSections(
    from rawSections: [RawSection],
    replyThreadAnchorMessage: FullMessage?
  ) -> [MessageSection] {
    var sections = rawSections.map { rawSection in
      MessageSection(
        date: rawSection.date,
        dayString: rawSection.dayString,
        items: rawSection.messages.map(Self.item(for:))
      )
    }

    guard let replyThreadAnchorMessage else { return sections }

    let anchorDate = Self.calendar.startOfDay(for: replyThreadAnchorMessage.message.date)
    let anchorItem = Self.anchorItem(for: replyThreadAnchorMessage)

    if let sectionIndex = sections.firstIndex(where: { Self.calendar.isDate($0.date, inSameDayAs: anchorDate) }) {
      guard sections[sectionIndex].items.contains(anchorItem) == false else {
        return sections
      }

      let rawMessages = rawSections[sectionIndex].messages + [replyThreadAnchorMessage]
      let sortedMessages = Self.sortMessagesForSection(rawMessages)
      sections[sectionIndex].items = sortedMessages.map { message in
        if Self.messageKey(for: message) == Self.messageKey(for: replyThreadAnchorMessage) {
          anchorItem
        } else {
          Self.item(for: message)
        }
      }
      return sections
    }

    let anchorSection = MessageSection(
      date: anchorDate,
      dayString: Self.formatDateForSection(anchorDate),
      items: [anchorItem]
    )

    if let insertIndex = sections.firstIndex(where: { $0.date < anchorDate }) {
      sections.insert(anchorSection, at: insertIndex)
    } else {
      sections.append(anchorSection)
    }

    return sections
  }

  static func buildRowItems(from sections: [MessageSection]) -> [RowItem] {
    var rowItems: [RowItem] = []
    rowItems.reserveCapacity(sections.reduce(0) { $0 + $1.items.count + 1 })

    for section in sections {
      rowItems.append(.daySeparator(dayStart: section.date))
      rowItems.append(contentsOf: section.items.map(RowItem.item))
    }

    return rowItems
  }

  nonisolated static func formatDateForSection(_ date: Date) -> String {
    let calendar = Calendar.current
    let messageDay = calendar.startOfDay(for: date)
    let today = Date()
    let todayStartOfDay = calendar.startOfDay(for: today)
    let yesterdayStartOfDay = calendar.date(byAdding: .day, value: -1, to: todayStartOfDay)!
    let currentYear = calendar.component(.year, from: today)

    if calendar.isDate(messageDay, inSameDayAs: todayStartOfDay) {
      return "Today"
    } else if calendar.isDate(messageDay, inSameDayAs: yesterdayStartOfDay) {
      return "Yesterday"
    } else {
      let messageYear = calendar.component(.year, from: messageDay)
      let formatter = DateFormatter()
      formatter.dateFormat = messageYear == currentYear ? "E, MMMM d" : "E, MMMM d, yyyy"
      return formatter.string(from: date)
    }
  }

  private static func item(for message: FullMessage) -> Item {
    .message(chatId: message.message.chatId, messageId: message.message.messageId)
  }

  private static func anchorItem(for message: FullMessage) -> Item {
    .replyThreadAnchor(chatId: message.message.chatId, messageId: message.message.messageId)
  }

  private static func messageKey(for message: FullMessage) -> MessageKey {
    MessageKey(chatId: message.message.chatId, messageId: message.message.messageId)
  }

  public enum SectionedMessagesChangeSet {
    case reload(animated: Bool?)
    case sectionsChanged(sections: [MessageSection])
    case itemsUpdated(sectionIndex: Int, itemIDs: [Item], animated: Bool?)
    case itemsAdded(sectionIndex: Int, itemIDs: [Item])
    case itemsDeleted(sectionIndex: Int, itemIDs: [Item])
    case multiSectionUpdate(sections: [MessageSection])
  }

  private func convertToSectionedChangeSet(
    from update: MessagesProgressiveViewModel
      .MessagesChangeSet
  ) -> SectionedMessagesChangeSet? {
    let previousSections = sections
    let previousMessagesByStableID = rawMessagesByStableID

    switch update {
      case let .reload(animated):
        rebuildSections()
        return .reload(animated: animated)

      case let .added(newMessages, _):
        rebuildSections()
        return makeAddedChangeSet(
          addedMessages: newMessages,
          previousSections: previousSections
        )

      case let .deleted(deletedIds, _):
        let deletedMessages = deletedIds.compactMap { previousMessagesByStableID[$0] }
        rebuildSections()
        return makeDeletedChangeSet(
          deletedMessages: deletedMessages,
          previousSections: previousSections
        )

      case let .updated(updatedMessages, _, animated):
        rebuildSections()
        return makeUpdatedChangeSet(
          updatedMessages: updatedMessages,
          previousSections: previousSections,
          animated: animated
        )
    }
  }

  private func makeAddedChangeSet(
    addedMessages: [FullMessage],
    previousSections: [MessageSection]
  ) -> SectionedMessagesChangeSet? {
    guard !addedMessages.isEmpty else { return nil }
    if sectionDates(in: previousSections) != sectionDates(in: sections) {
      return .sectionsChanged(sections: sections)
    }

    let affectedDays = Set(addedMessages.map { Self.calendar.startOfDay(for: $0.message.date) })
    guard let sectionIndex = singleSectionIndex(for: affectedDays, in: sections) else {
      return .multiSectionUpdate(sections: sections)
    }

    let currentSection = sections[sectionIndex]
    let previousItems = Set(previousSections[sectionIndex].items)
    let addedItems = currentSection.items.filter { !previousItems.contains($0) }
    let expectedItems = Set(addedMessages.map(Self.item(for:)))

    guard Set(addedItems) == expectedItems else {
      return .multiSectionUpdate(sections: sections)
    }

    return .itemsAdded(sectionIndex: sectionIndex, itemIDs: addedItems)
  }

  private func makeDeletedChangeSet(
    deletedMessages: [FullMessage],
    previousSections: [MessageSection]
  ) -> SectionedMessagesChangeSet? {
    guard !deletedMessages.isEmpty else {
      return .multiSectionUpdate(sections: sections)
    }
    if sectionDates(in: previousSections) != sectionDates(in: sections) {
      return .sectionsChanged(sections: sections)
    }

    let affectedDays = Set(deletedMessages.map { Self.calendar.startOfDay(for: $0.message.date) })
    guard let sectionIndex = singleSectionIndex(for: affectedDays, in: previousSections) else {
      return .multiSectionUpdate(sections: sections)
    }

    let currentItems = Set(sections[sectionIndex].items)
    let deletedItems = previousSections[sectionIndex].items.filter { !currentItems.contains($0) }
    let expectedItems = Set(deletedMessages.map(Self.item(for:)))

    guard Set(deletedItems) == expectedItems else {
      return .multiSectionUpdate(sections: sections)
    }

    return .itemsDeleted(sectionIndex: sectionIndex, itemIDs: deletedItems)
  }

  private func makeUpdatedChangeSet(
    updatedMessages: [FullMessage],
    previousSections: [MessageSection],
    animated: Bool?
  ) -> SectionedMessagesChangeSet? {
    guard !updatedMessages.isEmpty else { return nil }
    if sectionDates(in: previousSections) != sectionDates(in: sections) {
      return .sectionsChanged(sections: sections)
    }

    let affectedDays = Set(updatedMessages.map { Self.calendar.startOfDay(for: $0.message.date) })
    guard let sectionIndex = singleSectionIndex(for: affectedDays, in: sections) else {
      return .multiSectionUpdate(sections: sections)
    }

    let updatedItemsSet = Set(updatedMessages.map(Self.item(for:)))
    let updatedItems = sections[sectionIndex].items.filter { updatedItemsSet.contains($0) }

    guard !updatedItems.isEmpty else {
      return .multiSectionUpdate(sections: sections)
    }

    return .itemsUpdated(sectionIndex: sectionIndex, itemIDs: updatedItems, animated: animated)
  }

  private func sectionDates(in sections: [MessageSection]) -> [Date] {
    sections.map(\.date)
  }

  private func singleSectionIndex(
    for days: Set<Date>,
    in sections: [MessageSection]
  ) -> Int? {
    let matchingSections = sections.enumerated().filter { _, section in
      days.contains { Self.calendar.isDate(section.date, inSameDayAs: $0) }
    }
    guard matchingSections.count == 1 else { return nil }
    return matchingSections[0].offset
  }

  public func message(at indexPath: IndexPath) -> FullMessage? {
    guard let item = item(at: indexPath) else { return nil }
    return fullMessage(for: item)
  }

  public func numberOfSections() -> Int {
    sections.count
  }

  public func numberOfItems(in section: Int) -> Int {
    guard section >= 0, section < sections.count else {
      if section < 0 || section >= sections.count {
        log.warning("Invalid section index: \(section), sectionsCount=\(sections.count)")
      }
      return 0
    }
    return sections[section].items.count
  }

  public func section(at index: Int) -> MessageSection? {
    guard index >= 0, index < sections.count else {
      if index < 0 || index >= sections.count {
        log.warning("Invalid section index: \(index), sectionsCount=\(sections.count)")
      }
      return nil
    }
    return sections[index]
  }

  public func section(for date: Date) -> MessageSection? {
    sections.first { Self.calendar.isDate($0.date, inSameDayAs: date) }
  }

  public func item(at indexPath: IndexPath) -> Item? {
    guard indexPath.section >= 0,
          indexPath.section < sections.count,
          indexPath.item >= 0,
          indexPath.item < sections[indexPath.section].items.count
    else {
      log.warning(
        "Invalid index path: section=\(indexPath.section), item=\(indexPath.item), sectionsCount=\(sections.count)"
      )
      return nil
    }
    return sections[indexPath.section].items[indexPath.item]
  }

  public func rowItem(at row: Int) -> RowItem? {
    guard row >= 0, row < rowItems.count else {
      log.warning("Invalid row index: \(row), rowCount=\(rowItems.count)")
      return nil
    }
    return rowItems[row]
  }

  public func fullMessage(for item: Item) -> FullMessage? {
    switch item {
      case let .message(chatId, messageId):
        return rawMessagesByKey[MessageKey(chatId: chatId, messageId: messageId)]
      case let .replyThreadAnchor(chatId, messageId):
        if let replyThreadAnchorMessage,
           Self.messageKey(for: replyThreadAnchorMessage) == MessageKey(chatId: chatId, messageId: messageId)
        {
          return replyThreadAnchorMessage
        }
        return rawMessagesByKey[MessageKey(chatId: chatId, messageId: messageId)]
    }
  }

  public func fullMessage(for rowItem: RowItem) -> FullMessage? {
    guard case let .item(item) = rowItem else { return nil }
    return fullMessage(for: item)
  }
}

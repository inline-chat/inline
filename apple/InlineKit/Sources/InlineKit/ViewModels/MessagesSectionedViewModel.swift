import Combine
import Foundation
import Logger

/// A view model that bridges MessagesProgressiveViewModel and provides day-based sections
/// for use with collection views that need sticky date separators
@MainActor
public class MessagesSectionedViewModel {
  // MARK: - Static Resources (Performance Optimization)

  private static let calendar = Calendar.current
  private static let currentYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    // formatter.dateFormat = "MMMM d"
    formatter.dateFormat = "E, MMMM d"

    return formatter
  }()

  private static let otherYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    // formatter.dateFormat = "MMMM d, yyyy"
    formatter.dateFormat = "E, MMMM d, yyyy"
    return formatter
  }()

  public struct MessageSection {
    public let date: Date
    public let dayString: String
    public var messages: [FullMessage]

    public init(date: Date, dayString: String, messages: [FullMessage]) {
      self.date = date
      self.dayString = dayString
      self.messages = messages
    }
  }

  // MARK: - Public Properties

  public var sections: [MessageSection] = []
  public var messages: [FullMessage] { progressiveViewModel.messages }
  public var messagesByID: [Int64: FullMessage] { progressiveViewModel.messagesByID }

  // MARK: - Private Properties

  private let progressiveViewModel: MessagesProgressiveViewModel
  private let log = Log.scoped("MessagesSectionedViewModel")
  private var callback: ((_ changeSet: SectionedMessagesChangeSet) -> Void)?

  // MARK: - Init

  public init(peer: Peer, reversed: Bool = false) {
    progressiveViewModel = MessagesProgressiveViewModel(peer: peer, reversed: reversed)

    // Setup observer for progressive view model changes
    progressiveViewModel.observe { [weak self] update in
      guard let self else { return }
      log.trace("Received progressive update: \(update)")

      let sectionedUpdate = convertToSectionedChangeSet(from: update)
      callback?(sectionedUpdate)
    }

    // Initialize sections from current messages
    rebuildSections()
  }

  // MARK: - Public Methods

  public func observe(_ callback: @escaping (SectionedMessagesChangeSet) -> Void) {
    if self.callback != nil {
      log.warning("Callback already set, re-setting it to a new one will result in undefined behaviour")
    }
    self.callback = callback
  }

  public func loadBatch(at direction: MessagesProgressiveViewModel.MessagesLoadDirection) {
    progressiveViewModel.loadBatch(at: direction)
  }

  public func setAtBottom(_ atBottom: Bool) {
    progressiveViewModel.setAtBottom(atBottom)
  }

  public func dispose() {
    progressiveViewModel.dispose()
    callback = nil
  }

  // MARK: - Section Management

  private func rebuildSections() {
    let messages = progressiveViewModel.messages
    sections = groupMessagesByDay(messages)
  }

  private func groupMessagesByDay(_ messages: [FullMessage]) -> [MessageSection] {
    let grouped = Dictionary(grouping: messages) { message in
      Self.calendar.startOfDay(for: message.message.date)
    }

    let sortedKeys = grouped.keys.sorted { $0 > $1 } // Most recent first for reversed collection

    return sortedKeys.map { dayStart in
      let dayMessages = grouped[dayStart] ?? []
      let dayString = formatDateForSection(dayStart)

      // Sort messages within the day (newest first for reversed collection)
      let sortedMessages = dayMessages.sorted { $0.message.date > $1.message.date }

      return MessageSection(
        date: dayStart,
        dayString: dayString,
        messages: sortedMessages
      )
    }
  }

  private func formatDateForSection(_ date: Date) -> String {
    let messageDay = Self.calendar.startOfDay(for: date)
    let today = Date()
    let todayStartOfDay = Self.calendar.startOfDay(for: today)
    let yesterdayStartOfDay = Self.calendar.date(byAdding: .day, value: -1, to: todayStartOfDay)!
    let currentYear = Self.calendar.component(.year, from: today)

    if Self.calendar.isDate(messageDay, inSameDayAs: todayStartOfDay) {
      return "Today"
    } else if Self.calendar.isDate(messageDay, inSameDayAs: yesterdayStartOfDay) {
      return "Yesterday"
    } else {
      let messageYear = Self.calendar.component(.year, from: messageDay)
      let formatter = messageYear == currentYear ? Self.currentYearFormatter : Self.otherYearFormatter
      return formatter.string(from: date)
    }
  }

  // MARK: - Change Set Conversion

  public enum SectionedMessagesChangeSet {
    case reload(animated: Bool?)
    case sectionsChanged(sections: [MessageSection])
    case messagesUpdated(sectionIndex: Int, messageIds: [Int64], animated: Bool?)
    case messagesAdded(sectionIndex: Int, messageIds: [Int64])
    case messagesDeleted(sectionIndex: Int, messageIds: [Int64])
    case multiSectionUpdate(sections: [MessageSection]) // For when changes span multiple sections
  }

  private func convertToSectionedChangeSet(
    from update: MessagesProgressiveViewModel
      .MessagesChangeSet
  ) -> SectionedMessagesChangeSet {
    switch update {
      case let .reload(animated):
        rebuildSections()
        return .reload(animated: animated)

      case let .added(newMessages, _):
        // Determine which days the new messages belong to
        let newMessagesByDay = Dictionary(grouping: newMessages) { message in
          Self.calendar.startOfDay(for: message.message.date)
        }

        _ = sections.count
        var sectionsChanged = false

        // Check if we need new sections
        for dayStart in newMessagesByDay.keys {
          if !sections.contains(where: { Self.calendar.isDate($0.date, inSameDayAs: dayStart) }) {
            sectionsChanged = true
            break
          }
        }

        if sectionsChanged {
          // Need to add new sections, rebuild everything
          rebuildSections()
          return .sectionsChanged(sections: sections)
        } else {
          // All messages fit into existing sections, add incrementally
          var affectedSections: Set<Int> = []

          for (dayStart, dayMessages) in newMessagesByDay {
            if let sectionIndex = sections.firstIndex(where: { Self.calendar.isDate($0.date, inSameDayAs: dayStart) }),
               sectionIndex >= 0, sectionIndex < sections.count
            {
              // Add messages to existing section with bounds checking
              let sortedMessages = dayMessages.sorted { $0.message.date > $1.message.date }

              // Determine insertion point based on message dates
              // For reversed collection view: newest messages go at index 0
              let existingMessages = sections[sectionIndex].messages
              if existingMessages.isEmpty {
                // Empty section, just add all messages
                sections[sectionIndex].messages = sortedMessages
              } else {
                // Check if new messages are newer or older than existing ones
                let newestNewMessage = sortedMessages.first?.message.date ?? Date.distantPast
                let newestExistingMessage = existingMessages.first?.message.date ?? Date.distantPast

                if newestNewMessage > newestExistingMessage {
                  // New messages are newer, insert at beginning
                  sections[sectionIndex].messages.insert(contentsOf: sortedMessages, at: 0)
                } else {
                  // New messages are older, append at end
                  sections[sectionIndex].messages.append(contentsOf: sortedMessages)
                  // Re-sort to maintain proper order within the section
                  sections[sectionIndex].messages.sort { $0.message.date > $1.message.date }
                }
              }

              affectedSections.insert(sectionIndex)
            } else {
              log.warning("Could not find valid section for date: \(dayStart)")
            }
          }

          if affectedSections.count == 1, let singleSection = affectedSections.first {
            // Single section affected - use specific changeset
            let messageIds = newMessages.map(\.id)
            return .messagesAdded(sectionIndex: singleSection, messageIds: messageIds)
          } else if affectedSections.count > 1 {
            // Multiple sections affected - use multi-section update
            return .multiSectionUpdate(sections: sections)
          } else {
            // No sections found - fallback to full rebuild
            rebuildSections()
            return .sectionsChanged(sections: sections)
          }
        }

      case let .deleted(deletedIds, _):
        // Find which section contains the deleted messages before deletion
        let sectionIndex = findSectionContaining(messageIds: deletedIds)

        // Remove messages from sections with bounds checking
        for sectionIdx in sections.indices {
          guard sectionIdx >= 0, sectionIdx < sections.count else {
            log.warning("Invalid section index during deletion: \(sectionIdx)")
            continue
          }
          sections[sectionIdx].messages.removeAll { message in
            deletedIds.contains(message.id)
          }
        }

        // Remove empty sections
        let sectionsBeforeRemoval = sections.count
        sections.removeAll { $0.messages.isEmpty }
        let sectionsAfterRemoval = sections.count

        if sectionsBeforeRemoval != sectionsAfterRemoval {
          log.trace("Removed \(sectionsBeforeRemoval - sectionsAfterRemoval) empty sections")
          // Sections were removed, need to rebuild the collection view
          return .sectionsChanged(sections: sections)
        }

        return .messagesDeleted(sectionIndex: sectionIndex ?? 0, messageIds: deletedIds)

      case let .updated(updatedMessages, _, animated):
        // Find messages and update them in place
        let messageUpdates = Dictionary(uniqueKeysWithValues: updatedMessages.map { ($0.id, $0) })
        var updatedSectionIndex: Int?

        for sectionIdx in sections.indices {
          for messageIdx in sections[sectionIdx].messages.indices {
            let messageId = sections[sectionIdx].messages[messageIdx].id
            if let updatedMessage = messageUpdates[messageId] {
              sections[sectionIdx].messages[messageIdx] = updatedMessage
              updatedSectionIndex = sectionIdx
            }
          }
        }

        let messageIds = updatedMessages.map(\.id)
        if let sectionIndex = updatedSectionIndex {
          return .messagesUpdated(sectionIndex: sectionIndex, messageIds: messageIds, animated: animated)
        } else {
          // Fallback to full rebuild if messages not found
          rebuildSections()
          return .sectionsChanged(sections: sections)
        }
    }
  }

  private func findSectionContaining(messageIds: [Int64]) -> Int? {
    for (sectionIndex, section) in sections.enumerated() {
      let sectionMessageIds = Set(section.messages.map(\.id))
      if messageIds.contains(where: { sectionMessageIds.contains($0) }) {
        return sectionIndex
      }
    }
    return nil
  }

  // MARK: - Section Helpers

  public func message(at indexPath: IndexPath) -> FullMessage? {
    guard indexPath.section >= 0,
          indexPath.section < sections.count,
          indexPath.item >= 0,
          indexPath.item < sections[indexPath.section].messages.count
    else {
      log
        .warning(
          "Invalid index path: section=\(indexPath.section), item=\(indexPath.item), sectionsCount=\(sections.count)"
        )
      return nil
    }
    return sections[indexPath.section].messages[indexPath.item]
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
    return sections[section].messages.count
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
}

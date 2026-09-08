import Foundation
import InlineKit

public enum ExperimentalMessageListRow: Equatable, Hashable, Sendable {
  case daySeparator(dayStart: Date)
  case unreadSeparator
  case repliesSeparator
  case collapsedHistory
  case historyHole(afterID: Int64, beforeID: Int64)
  case parentMessage(id: Int64)
  case message(id: Int64)
}

public enum ExperimentalMessageListRowProjection {
  public typealias Row = ExperimentalMessageListRow

  /// A content change can affect both occurrences of a message and the adjacent
  /// message grouping. Synthetic rows are stable boundaries, not reload targets.
  public static func rowsToReload(changedMessageIDs: Set<Int64>, in rows: [Row]) -> IndexSet {
    var affected = IndexSet()
    for (index, row) in rows.enumerated() {
      switch row {
        case let .message(id), let .parentMessage(id):
          guard changedMessageIDs.contains(id) else { continue }
          affected.insert(index)
        default:
          continue
      }
      for neighbor in [index - 1, index + 1] where rows.indices.contains(neighbor) {
        if case .message = rows[neighbor] { affected.insert(neighbor) }
      }
    }
    return affected
  }

  public static func makeRows(
    messages: [FullMessage],
    showUnreadAfter: Int64?,
    showsCollapsedHistory: Bool,
    parentMessageStableId: Int64?,
    coverage: MessageHistoryCoverageProjection
  ) -> [Row] {
    var out: [Row] = []
    out.reserveCapacity(messages.count + 9)

    if let parentMessageStableId {
      out.append(.parentMessage(id: parentMessageStableId))
      out.append(.repliesSeparator)
    }

    if showsCollapsedHistory {
      out.append(.collapsedHistory)
    }

    var prevDayStart: Date?
    var didInsertUnread = false
    var previousMessageID: Int64?

    for msg in messages {
      let messageID = msg.message.messageId
      if let previousMessageID, previousMessageID > 0, messageID > 0,
         !coverage.isCertifiedContinuation(between: previousMessageID, and: messageID)
      {
        out.append(.historyHole(
          afterID: min(previousMessageID, messageID),
          beforeID: max(previousMessageID, messageID)
        ))
      }
      if messageID > 0 { previousMessageID = messageID }
      let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: msg.message.date)
      if prevDayStart == nil || dayStart != prevDayStart {
        out.append(.daySeparator(dayStart: dayStart))
        prevDayStart = dayStart
      }

      if !didInsertUnread,
         let showUnreadAfter,
         msg.message.messageId > showUnreadAfter
      {
        out.append(.unreadSeparator)
        didInsertUnread = true
      }

      out.append(.message(id: msg.id))
    }

    return out
  }
}

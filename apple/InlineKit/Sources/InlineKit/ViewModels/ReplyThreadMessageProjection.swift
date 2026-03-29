import Foundation

public enum ReplyThreadMessageProjection {
  public static func project(parentMessage: FullMessage?, replies: [FullMessage]) -> [FullMessage] {
    guard let parentMessage else { return replies }

    let parentKey = messageKey(for: parentMessage)
    guard replies.contains(where: { messageKey(for: $0) == parentKey }) == false else {
      return replies
    }

    return [parentMessage] + replies
  }

  public static func rowIndexesForUpdatedMessages(
    _ updatedMessages: [FullMessage],
    rowIndexByStableId: [Int64: Int]
  ) -> IndexSet {
    var rows = IndexSet()

    for message in updatedMessages {
      if let row = rowIndexByStableId[message.id] {
        rows.insert(row)
      }
    }

    return rows
  }

  private static func messageKey(for message: FullMessage) -> String {
    "\(message.message.chatId):\(message.message.messageId)"
  }
}

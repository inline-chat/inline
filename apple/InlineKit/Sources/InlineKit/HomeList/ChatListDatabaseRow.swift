import GRDB

/// Indexed decoder for the fixed chat-list SELECT layout.
///
/// GRDB's name-based Row subscript performs a case-insensitive column lookup for every access.
/// Snapshot projection reads dozens of values per dialog, so resolving that layout repeatedly was
/// the dominant named cost in the physical-device trace. This wrapper keeps the SQL readable while
/// making every per-row value access an O(1) integer subscript.
struct ChatListDatabaseRow {
  enum Column: Int, CaseIterable {
    case peerUserID
    case peerThreadID
    case chatID
    case spaceID
    case unreadCount
    case unreadMark
    case isArchived
    case isPinned
    case isOpen
    case openedDate
    case normalOrder
    case pinnedOrder
    case followMode
    case chatDate
    case chatType
    case chatTitle
    case chatEmoji
    case parentMessageID
    case peerFirstName
    case peerLastName
    case peerEmail
    case peerUsername
    case peerPhoneNumber
    case profileFileID
    case profileFileUniqueID
    case profileCDNURL
    case profileLocalPath
    case lastMessageID
    case lastMessageDate
    case lastMessageText
    case lastMessageRevision
    case lastMessageIsSticker
    case lastMessageFileID
    case lastMessagePhotoID
    case lastMessageVideoID
    case lastMessageDocumentID
    case lastMessageContentPayload
    case lastDocumentFileName
    case senderFirstName
    case senderLastName
    case senderEmail
    case senderUsername
    case senderPhoneNumber
    case draftText
    case draftRevision
    case draftHasAttachments
    case legacyDraftMessage
    case anchorMessageText
    case anchorMessageID
    case anchorMessageIsSticker
    case anchorMessageFileID
    case anchorMessagePhotoID
    case anchorMessageVideoID
    case anchorMessageDocumentID
    case anchorMessageContentPayload
  }

  private let row: Row

  init(_ row: Row) {
    self.row = row
  }

  subscript<Value: DatabaseValueConvertible>(_ column: Column) -> Value {
    row[column.rawValue]
  }

  #if DEBUG
  static func validateLayout(of row: Row) {
    let actual = Array(row.columnNames)
    let expected = Column.allCases.map { String(describing: $0) }
    precondition(
      actual == expected,
      "Chat-list SQL/decoder column mismatch. Expected \(expected), received \(actual)."
    )
  }
  #endif
}

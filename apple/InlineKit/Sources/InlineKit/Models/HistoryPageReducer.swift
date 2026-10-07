import GRDB
import InlineProtocol

/// Runs exclusively inside one writer transaction. A failed row or reference
/// rolls back both canonical data and every hole operation.
enum HistoryPageReducer {
  static func validateMessages(
    _ messages: [InlineProtocol.Message], chatId: Int64, peer: Peer,
    scope: MessageHistoryScope = .timeline, descending: Bool = true
  ) throws {
    var seen: Set<Int64> = []
    var previous = MessageHistoryHole.positiveMessageIDMax + 1
    for message in messages {
      guard 1 ... MessageHistoryHole.positiveMessageIDMax ~= message.id,
            message.chatID == chatId, message.fromID > 0,
            seen.insert(message.id).inserted,
            !descending || message.id < previous
      else { throw HistoryPageAdmissionError.malformedPage }
      switch (peer, message.peerID.type) {
        case let (.thread(id), .chat(value)) where value.chatID == id: break
        case let (.user(id), .user(value)) where value.userID == id: break
        default: throw HistoryPageAdmissionError.malformedPage
      }
      if message.hasMedia {
        switch message.media.media {
          case let .photo(value):
            guard value.hasPhoto, value.photo.id > 0 else { throw HistoryPageAdmissionError.malformedPage }
          case let .video(value):
            guard value.hasVideo, value.video.id > 0 else { throw HistoryPageAdmissionError.malformedPage }
            if value.video.hasPhoto, value.video.photo.id <= 0 {
              throw HistoryPageAdmissionError.malformedPage
            }
          case let .document(value):
            guard value.hasDocument, value.document.id > 0 else { throw HistoryPageAdmissionError.malformedPage }
            if value.document.hasPhoto, value.document.photo.id <= 0 {
              throw HistoryPageAdmissionError.malformedPage
            }
          case let .voice(value):
            guard value.hasVoice, value.voice.id > 0 else { throw HistoryPageAdmissionError.malformedPage }
          case .nudge: break
          case nil: throw HistoryPageAdmissionError.malformedPage
        }
      }
      var attachmentIDs: Set<Int64> = []
      for attachment in message.attachments.attachments {
        guard attachment.id > 0,
              attachmentIDs.insert(attachment.id).inserted else { throw HistoryPageAdmissionError.malformedPage }
        switch attachment.attachment {
          case let .externalTask(task):
            guard task.id > 0 else { throw HistoryPageAdmissionError.malformedPage }
          case let .urlPreview(preview):
            guard preview.id > 0 else { throw HistoryPageAdmissionError.malformedPage }
          case nil: throw HistoryPageAdmissionError.malformedPage
        }
      }
      if scope != .timeline {
        guard !MessageResourceFlags.classify(message).intersection(scope.resourceMask).isEmpty
        else { throw HistoryPageAdmissionError.malformedPage }
      }
      previous = message.id
    }
  }

  @discardableResult
  static func save(
    _ messages: [InlineProtocol.Message], db: Database
  ) throws -> [Message] {
    try messages.map {
      try Message.save(db, protocolMessage: $0, materializeMissingReferences: true, authoritativeSnapshot: true)
    }
  }

  static func admitCoverage(
    _ ranges: [ClosedRange<Int64>], messages: [InlineProtocol.Message],
    chatId: Int64, scope: MessageHistoryScope,
    token: HistoryPageAdmissionToken, db: Database
  ) throws {
    let returned = Set(messages.map(\.id))
    let finiteUpper = max(token.knownMaxMessageId, returned.max() ?? 0)
    var changedMembership = false
    for range in ranges {
      let upper = min(range.upperBound, finiteUpper)
      if range.lowerBound <= upper {
        let rows = try Row.fetchAll(
          db,
          sql: "SELECT messageId, resourceFlags, status FROM message WHERE chatId = ? AND messageId BETWEEN ? AND ?",
          arguments: [chatId, range.lowerBound, upper]
        )
        var deleted: [Int64] = []
        for row in rows {
          let id: Int64 = row["messageId"]
          guard !returned.contains(id) else { continue }
          let status: Int64? = row["status"]
          guard status == nil || status == MessageSendingStatus.sent.rawValue else { continue }
          if scope == .timeline {
            deleted.append(id)
          } else {
            let flags: Int64 = row["resourceFlags"]
            let replacement = flags & ~scope.resourceMask.rawValue
            if replacement != flags {
              try db.execute(
                sql: "UPDATE message SET resourceFlags = ? WHERE chatId = ? AND messageId = ?",
                arguments: [replacement, chatId, id]
              )
              changedMembership = true
            }
          }
        }
        if !deleted.isEmpty {
          try Message.deleteMessages(db, messageIds: deleted, chatId: chatId)
          changedMembership = true
        }
      }
      if scope == .timeline {
        try MessageHistoryCoverageStore.subtractAll(
          db,
          chatId: chatId,
          lowerId: range.lowerBound,
          upperId: range.upperBound
        )
      } else {
        try MessageHistoryCoverageStore.subtract(
          db,
          chatId: chatId,
          scope: scope,
          lowerId: range.lowerBound,
          upperId: range.upperBound
        )
      }
    }
    if changedMembership {
      try HistoryPageAdmissionToken.advanceRevision(db, chatId: chatId)
    }
  }

  /// Exact-ID lookup has authority only over its requested coordinates. It
  /// never fills a numeric interval, including the spaces between these IDs.
  static func reconcileExactAbsences(
    requested: Set<Int64>, returned: Set<Int64>, chatId: Int64,
    token: HistoryPageAdmissionToken, db: Database
  ) throws {
    let absent = requested.subtracting(returned).filter { $0 <= token.knownMaxMessageId }
    guard !absent.isEmpty else { return }
    let confirmed = try Message.filter(Message.Columns.chatId == chatId)
      .filter(absent.contains(Message.Columns.messageId))
      .filter(sql: "status IS NULL OR status = 1")
      .select(Message.Columns.messageId).asRequest(of: Int64.self).fetchAll(db)
    if !confirmed.isEmpty {
      try Message.deleteMessages(db, messageIds: confirmed, chatId: chatId)
    }
  }
}

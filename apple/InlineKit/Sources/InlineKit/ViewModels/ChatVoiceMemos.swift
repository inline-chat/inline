import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger

public struct VoiceMemoMessage: Identifiable, Equatable, Sendable {
  public var id: Int64 {
    message.messageId
  }

  public let message: Message
  public let voice: Client_MessageVoiceContent
}

public struct VoiceMemoMessageGroup {
  public let date: Date
  public let messages: [VoiceMemoMessage]
}

@MainActor
public final class ChatVoiceMemosViewModel: ChatResourceWindow<VoiceMemoMessage>, @unchecked Sendable {
  public var voiceMemoMessages: [VoiceMemoMessage] {
    rows
  }

  public init(db: AppDatabase, chatId: Int64, peer: Peer) {
    super.init(
      db: db,
      chatId: chatId,
      peer: peer,
      scope: .voice,
      fetchRows: { db, limit in
        try Message.filter(Message.Columns.chatId == chatId)
          .filter(sql: "resourceFlags & ? != 0", arguments: [MessageHistoryScope.voice.resourceMask.rawValue])
          .order(Message.Columns.messageId.desc)
          .limit(limit)
          .fetchAll(db)
          .compactMap { message in
            message.voiceContent.map { VoiceMemoMessage(message: message, voice: $0) }
          }
      },
      messageID: { $0.message.messageId }
    )
  }

  @Published public private(set) var groupedVoiceMemoMessages: [VoiceMemoMessageGroup] = []

  override public func rowsDidChange() {
    groupedVoiceMemoMessages = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.message.date) }
      .map { VoiceMemoMessageGroup(date: $0.key, messages: $0.value.sorted { lhs, rhs in
        if lhs.message.date != rhs.message.date {
          return lhs.message.date > rhs.message.date
        }
        return lhs.message.messageId > rhs.message.messageId
      }) }
      .sorted { $0.date > $1.date }
  }
}

import Combine
import GRDB
import SwiftUI

public struct FullMessage2: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64 {
    message.id
  }

  public var message: Message
  public var from: User
  public var repliedToMessage: Message?

  public init(message: Message, from: User, repliedToMessage: Message?) {
    self.message = message
    self.from = from
    self.repliedToMessage = repliedToMessage
  }
}

public final class FullMessageViewModel: ObservableObject, @unchecked Sendable {
  var messageId: Int64
  var chatId: Int64
  @Published public private(set) var fullMessage: FullMessage?
  private var cancellable: AnyCancellable?
  private var db: AppDatabase

  public init(db: AppDatabase, messageId: Int64, chatId: Int64) {
    self.db = db
    self.messageId = messageId
    self.chatId = chatId

    fetchMessage(messageId, chatId: self.chatId)
  }

  public func fetchMessage(_ msgId: Int64, chatId: Int64) {
    let messageId = self.messageId
    cancellable =
      ValueObservation
        .tracking { db in
          try Message
            .filter(Column("messageId") == messageId && Column("chatId") == chatId)
            .including(optional: Message.from.forKey("from"))
            .including(optional: Message.repliedToMessage)
            .including(optional: Message.reactions)
            .asRequest(of: FullMessage.self)
            .fetchOne(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { Log.shared.error("Failed to get full message \($0)") },
          receiveValue: { [weak self] message in
            self?.fullMessage = message
          }
        )
  }
}

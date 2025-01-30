import Combine
import GRDB
import SwiftUI

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
    let messageId = messageId
    cancellable =
      ValueObservation
        .tracking { db in
          try Message
            .filter(Column("messageId") == messageId && Column("chatId") == chatId)
            .including(optional: Message.file)
            .including(optional: Message.from.forKey("from"))
            .including(all: Message.reactions)
            .including(optional: Message.repliedToMessage.forKey("repliedToMessage"))
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

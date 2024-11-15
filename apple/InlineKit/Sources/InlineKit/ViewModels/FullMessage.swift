import Combine
import GRDB

public struct FullMessage: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable,
  Identifiable
{
  public var user: User?
  public var message: Message

  public var id: Int64 {
    message.id
  }
}

public final class FullMessageViewModel: ObservableObject, @unchecked Sendable {
  @Published public private(set) var fullMessage: FullMessage? = nil

  private var cancellable: AnyCancellable?

  private var db: AppDatabase
  private var messageId: Int64

  public init(db: AppDatabase, messageId: Int64) {
    self.db = db
    self.messageId = messageId
    fetchFullMessage()
  }

  func fetchFullMessage() {
    cancellable =
      ValueObservation
        .tracking { db in
          try Message
            .filter(Column("messageId") == self.messageId)
            .including(optional: Message.from)
            .asRequest(of: FullMessage.self)
            .fetchOne(db)
        }
        .publisher(in: db.dbWriter)
        .sink(
          receiveCompletion: { completion in
            print("fetchFullMessage completion: \(completion)")
          },
          receiveValue: { message in
            self.fullMessage = message
          }
        )
  }
}

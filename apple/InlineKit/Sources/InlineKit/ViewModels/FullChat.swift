import Combine
import GRDB

public final class FullChatViewModel: ObservableObject {
    @Published public private(set) var chat: Chat?
    @Published public private(set) var messages: [Message] = []

    private var chatCancellable: AnyCancellable?
    private var messagesCancellable: AnyCancellable?

    private var db: AppDatabase
    private var chatId: Int64

    public init(db: AppDatabase, chatId: Int64) {
        self.db = db
        self.chatId = chatId
        fetchChat()
        fetchMessages()
    }

    func fetchMessages() {
        messagesCancellable = ValueObservation
            .tracking { db in
                try Message.filter(Column("chatId") == self.chatId)
                    .order(Column("date").desc)
                    .fetchAll(db)
            }
            .publisher(in: db.dbWriter, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in /* ignore error */ },
                receiveValue: { [weak self] messages in
                    self?.messages = messages
                }
            )
    }

    func fetchChat() {
        chatCancellable = ValueObservation
            .tracking { db in
                try Chat.fetchOne(db, id: self.chatId)
            }
            .publisher(in: db.dbWriter, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in /* ignore error */ },
                receiveValue: { [weak self] chat in
                    self?.chat = chat
                }
            )
    }
}

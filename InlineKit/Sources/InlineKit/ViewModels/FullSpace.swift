import Combine
import GRDB

public struct SpaceChatItem: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable, Identifiable {
    public var dialog: Dialog?
    // Useful for threads
    public var chat: Chat
    // Only for private chats
    public var user: User?
    // Last message
    public var message: Message?

    // Peer user
    public var peerId: Peer {
        if let user = user {
            return Peer(userId: user.id)
        }
        return Peer(threadId: chat.id)
    }

    public var id: Int64 {
        chat.id
    }
}

// Used for space home sidebar
public final class FullSpaceViewModel: ObservableObject {
    /// The spaces to display.
    @Published public private(set) var space: Space?
    @Published public private(set) var members: [Member] = []
    @Published public private(set) var chats: [SpaceChatItem] = []

    private var spaceSancellable: AnyCancellable?
    private var membersSancellable: AnyCancellable?
    private var chatsSancellable: AnyCancellable?

    private var db: AppDatabase
    private var spaceId: Int64
    public init(db: AppDatabase, spaceId: Int64) {
        self.db = db
        self.spaceId = spaceId
        fetchSpace()
        fetchMembers()
        fetchChats()
    }

    func fetchSpace() {
        let spaceId = self.spaceId
        spaceSancellable =
            ValueObservation
                .tracking { db in
                    try Space.fetchOne(db, id: spaceId)
                }
                .publisher(in: db.dbWriter, scheduling: .immediate)
                .sink(
                    receiveCompletion: { _ in /* ignore error */ },
                    receiveValue: { [weak self] space in
                        self?.space = space
                    })
    }

    func fetchMembers() {
        let spaceId = self.spaceId
        membersSancellable =
            ValueObservation
                .tracking { db in
                    try Member.filter(Column("spaceId") == spaceId)
                        .fetchAll(db)
                }
                .publisher(in: db.dbWriter, scheduling: .immediate)
                .sink(
                    receiveCompletion: { _ in /* ignore error */ },
                    receiveValue: { [weak self] members in
                        self?.members = members
                    })
    }

    func fetchChats() {
        let spaceId = self.spaceId
        chatsSancellable =
            ValueObservation
                .tracking { db in
                    try Dialog.filter(Column("spaceId") == spaceId)
                        .including(
                            optional: Dialog.peerThread
                                .including(optional: Chat.lastMessage)
                        )
                        .including(
                            optional: Dialog.peerUser
                                .including(optional: User.chat)
                        )
                        .asRequest(of: SpaceChatItem.self)
                        .fetchAll(db)
                }
                .publisher(in: db.dbWriter, scheduling: .immediate)
                .sink(
                    receiveCompletion: { error in
                        print("error: \(error)")
                    },
                    receiveValue: { [weak self] chats in
                        print("\(chats)")
                        self?.chats = chats
                    })
    }
}

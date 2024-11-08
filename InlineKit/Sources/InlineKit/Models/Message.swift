import Foundation
import GRDB

public struct ApiMessage: Codable, Hashable, Sendable {
    public var id: Int64
    public var peerId: Peer
    public var fromId: Int64
    // Raw message text
    public var text: String?
    public var mentioned: Bool?
    public var pinned: Bool?
    public var out: Bool?
    public var editDate: Int?
    public var date: Int
}

public struct Message: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, Sendable {
    public var id: Int64
    public var date: Date
    
    // Raw message text
    public var text: String?
    
    // One of these must be set
    public var peerUserId: Int64?
    public var peerThreadId: Int64?
    
    // Sent from user
    public var fromId: Int64
    
    // Are we mentioned in this message?
    public var mentioned: Bool?
    
    // Is this message outgoing?
    public var out: Bool?
    
    // is this message pinned?
    public var pinned: Bool?
    
    // If message was edited
    public var editDate: Date?

    public static let chat = belongsTo(Chat.self)
    public var chat: QueryInterfaceRequest<Chat> {
        request(for: Message.chat)
    }

    public static let from = belongsTo(User.self)
    public var from: QueryInterfaceRequest<User> {
        request(for: Message.from)
    }

    public init(
        id: Int64 = Int64.random(in: 1 ... 5000),
        fromId: Int64,
        date: Date,
        text: String?,
        peerUserId: Int64?,
        peerThreadId: Int64?,
        out: Bool? = nil,
        mentioned: Bool? = nil,
        pinned: Bool? = nil,
        editDate: Date? = nil)
    {
        self.id = id
        self.date = date
        self.text = text
        self.fromId = fromId
        self.peerUserId = peerUserId
        self.peerThreadId = peerThreadId
        self.editDate = editDate
        self.out = out
        self.mentioned = mentioned
        self.pinned = pinned
            
        if peerUserId == nil && peerThreadId == nil {
            fatalError("One of peerUserId or peerThreadId must be set")
        }
    }
}

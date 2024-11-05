import Foundation
import GRDB

public struct ApiSpace: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked Sendable {
    // Min
    public var id: Int64
    public var name: String
    public var date: Int
    
    // Extra
    public var creator: Bool?
}

public struct Space: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked Sendable {
    public var id: Int64
    
    // Space name
    public var name: String
    
    public var date: Date
    
    // Are we creator of the space?
    public var creator: Bool?

    // Based on https://github.com/groue/GRDB.swift/discussions/1492, GRDB models can't be marked as sendable in GRDB < 6 so we should use  . This issue was fixed in GRDB 7, but because we use GRDB + SQLCipher from Duck Duck Go, we can't upgrade GRDB from v 6 to 7, and the discussions and issues are not open.
    public static let members = hasMany(Member.self)
    public static let users = hasMany(User.self, through: members, using: Member.user)

    public var users: QueryInterfaceRequest<User> {
        request(for: Space.users)
    }

    public var members: QueryInterfaceRequest<Member> {
        request(for: Space.members)
    }

    public static let chats = hasMany(Chat.self)
    public var chats: QueryInterfaceRequest<Chat> {
        request(for: Space.chats)
    }

    /// NOTE(@mo): `Int64.random(in: 1 ... 5000)` using this is dangerous because it can generate the same number for different spaces, and it will cause a conflict with the API.
    public init(id: Int64 = Int64.random(in: 1 ... 5000), name: String, date: Date, creator: Bool? = nil) {
        self.id = id
        self.name = name
        self.date = date
        self.creator = creator
    }
}

public extension Space {
    init(from apiSpace: ApiSpace) {
        id = apiSpace.id
        name = apiSpace.name
        creator = apiSpace.creator
        date = Self.fromTimestamp(from: apiSpace.date)
    }

    static func fromTimestamp(from: Int) -> Date {
        return Date(timeIntervalSince1970: Double(from) / 1000)
    }
}

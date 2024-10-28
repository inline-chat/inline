import Foundation
import GRDB

public struct ApiUser: Codable, Hashable, Sendable {
    public var id: Int64
    public var email: String?
    public var firstName: String?
    public var lastName: String?
    public var date: Int
    public var username: String?
}

public struct User: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked Sendable {
    public var id: Int64
    public var email: String?
    public var firstName: String?
    public var lastName: String?
    public var date: Date?
    public var username: String?

    public nonisolated(unsafe) static let members = hasMany(Member.self)
    public nonisolated(unsafe) static let spaces = hasMany(Space.self, through: members, using: Member.space)

    public var members: QueryInterfaceRequest<Member> {
        request(for: User.members)
    }

    public var spaces: QueryInterfaceRequest<Space> {
        request(for: User.spaces)
    }

    public nonisolated(unsafe) static let chats = hasMany(Chat.self)
    public var chats: QueryInterfaceRequest<Chat> {
        request(for: User.chats)
    }

    public nonisolated(unsafe) static let messages = hasMany(Message.self)
    public var messages: QueryInterfaceRequest<Message> {
        request(for: User.messages)
    }

    public init(id: Int64 = Int64.random(in: 1 ... 5000), email: String?, firstName: String?, lastName: String? = nil, username: String? = nil) {
        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        date = Date.now
        self.username = username
    }
}

public extension User {
    init(from apiUser: ApiUser) {
        id = apiUser.id
        email = apiUser.email
        firstName = apiUser.firstName
        lastName = apiUser.lastName
        username = apiUser.username
        date = Self.fromTimestamp(from: apiUser.date)
    }

    static func fromTimestamp(from: Int) -> Date {
        return Date(timeIntervalSince1970: Double(from) / 1000)
    }
}

public extension User {
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case firstName
        case lastName
        case date
        case username
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(Int64.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? .now
    }
}

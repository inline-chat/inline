import Foundation
import GRDB

public struct User: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked Sendable {
    public var id: Int64
    public var email: String
    public var firstName: String
    public var lastName: String?
    public var createdAt: Date?

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

    public init(id: Int64 = Int64.random(in: 1 ... 5000), email: String, firstName: String, lastName: String? = nil) {
        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        createdAt = Date.now
    }
}

public extension User {
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case firstName
        case lastName
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(Int64.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
}

import Foundation
import GRDB

public struct User: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord {
    public var id: Int64
    public var email: String
    public var firstName: String
    public var lastName: String?
    public var createdAt: Date?

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

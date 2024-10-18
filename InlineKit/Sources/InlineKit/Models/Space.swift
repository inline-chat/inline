import Foundation
import GRDB

public struct Space: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked Sendable {
    public var id: Int64
    public var name: String
    public var createdAt: Date

    // Based on https://github.com/groue/GRDB.swift/discussions/1492, GRDB models can't be marked as sendable in GRDB < 6 so we should use nonisolated(unsafe). This issue was fixed in GRDB 7, but because we use GRDB + SQLCipher from Duck Duck Go, we can't upgrade GRDB from v 6 to 7, and the discussions and issues are not open.
    public nonisolated(unsafe) static let members = hasMany(Member.self)
    public nonisolated(unsafe) static let users = hasMany(User.self, through: members, using: Member.user)

    public var users: QueryInterfaceRequest<User> {
        request(for: Space.users)
    }

    public var members: QueryInterfaceRequest<Member> {
        request(for: Space.members)
    }

    public init(id: Int64 = Int64.random(in: 1 ... 5000), name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

import Foundation
import GRDB

public struct Member: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked Sendable {
    public var id: Int64
    public var createdAt: Date
    public var userId: Int64
    public var spaceId: Int64

    // Member -> Space
    public nonisolated(unsafe) static let space = belongsTo(Space.self)
    public var space: QueryInterfaceRequest<Space> {
        request(for: Member.space)
    }

    // Member -> User
    public nonisolated(unsafe) static let user = belongsTo(User.self)
    public var user: QueryInterfaceRequest<User> {
        request(for: Member.user)
    }

    public init(id: Int64 = Int64.random(in: 1 ... 5000), createdAt: Date, userId: Int64, spaceId: Int64) {
        self.id = id
        self.createdAt = createdAt
        self.userId = userId
        self.spaceId = spaceId
    }
}

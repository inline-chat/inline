import Foundation
import GRDB

public struct SpaceMemberDialogArchiveState: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: Int64?
  public var spaceId: Int64
  public var peerUserId: Int64
  public var archived: Bool
  public var updatedAt: Date

  public enum Columns {
    public static let id = Column(CodingKeys.id)
    public static let spaceId = Column(CodingKeys.spaceId)
    public static let peerUserId = Column(CodingKeys.peerUserId)
    public static let archived = Column(CodingKeys.archived)
    public static let updatedAt = Column(CodingKeys.updatedAt)
  }

  public static let databaseTableName = "spaceMemberDialogArchiveState"

  public init(
    id: Int64? = nil,
    spaceId: Int64,
    peerUserId: Int64,
    archived: Bool,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.spaceId = spaceId
    self.peerUserId = peerUserId
    self.archived = archived
    self.updatedAt = updatedAt
  }
}

public extension SpaceMemberDialogArchiveState {
  static func archivedPeerUserIds(db: Database, spaceId: Int64) throws -> Set<Int64> {
    let rows = try SpaceMemberDialogArchiveState
      .filter(Columns.spaceId == spaceId)
      .filter(Columns.archived == true)
      .fetchAll(db)

    return Set(rows.map(\.peerUserId))
  }
}

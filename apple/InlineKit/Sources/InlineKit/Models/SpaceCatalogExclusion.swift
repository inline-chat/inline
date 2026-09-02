import GRDB

/// A cached Space remains available to retained chats and messages while this
/// user-owned marker removes it from active catalog projections.
public struct SpaceCatalogExclusion: Codable, FetchableRecord, PersistableRecord, Sendable {
  public static let databaseTableName = "spaceCatalogExclusion"

  public var spaceId: Int64

  public init(spaceId: Int64) {
    self.spaceId = spaceId
  }

  public enum Columns {
    public static let spaceId = Column(CodingKeys.spaceId)
  }
}

/// Records an exact peer omitted by an admitted account catalog rebase while
/// preserving its Dialog-owned read state and its Chat and Message cache.
public struct DialogCatalogExclusion: Codable, FetchableRecord, PersistableRecord, Sendable {
  public static let databaseTableName = "dialogCatalogExclusion"

  public var dialogId: Int64

  public init(dialogId: Int64) {
    self.dialogId = dialogId
  }

  public enum Columns {
    public static let dialogId = Column(CodingKeys.dialogId)
  }
}

public enum SpaceCatalogStore {
  public static func activeSpaceIDs(_ db: Database) throws -> Set<Int64> {
    Set(try Space
      .catalogActive()
      .fetchAll(db)
      .map(\.id))
  }

  /// Replaces only active-catalog inclusion. Space, Chat, Message, and File
  /// cache rows are deliberately untouched.
  @discardableResult
  public static func replaceActiveSpaceIDs(
    _ activeIDs: Set<Int64>,
    in db: Database
  ) throws -> Set<Int64> {
    let existingActiveIDs = try activeSpaceIDs(db)
    let omittedIDs = existingActiveIDs.subtracting(activeIDs)

    if !activeIDs.isEmpty {
      try SpaceCatalogExclusion
        .filter(activeIDs.contains(SpaceCatalogExclusion.Columns.spaceId))
        .deleteAll(db)
    }
    for spaceID in omittedIDs {
      try SpaceCatalogExclusion(spaceId: spaceID).save(db)
    }
    return omittedIDs
  }

  public static func include(spaceID: Int64, in db: Database) throws {
    guard spaceID > 0 else { return }
    try SpaceCatalogExclusion
      .filter(SpaceCatalogExclusion.Columns.spaceId == spaceID)
      .deleteAll(db)
  }
}

public enum DialogCatalogStore {
  public static func exclude(dialogID: Int64, in db: Database) throws {
    try DialogCatalogExclusion(dialogId: dialogID).save(db)
  }

  public static func include(dialogID: Int64, in db: Database) throws {
    try DialogCatalogExclusion
      .filter(DialogCatalogExclusion.Columns.dialogId == dialogID)
      .deleteAll(db)
  }
}

public extension Space {
  static func catalogActive() -> QueryInterfaceRequest<Space> {
    filter(sql: """
      NOT EXISTS (
        SELECT 1
        FROM "spaceCatalogExclusion"
        WHERE "spaceCatalogExclusion"."spaceId" = "space"."id"
      )
      """)
  }
}

import Foundation
import GRDB
import InlineProtocol

public struct SpaceRecoverySettings: Codable, FetchableRecord, PersistableRecord, Sendable {
  public static let databaseTableName = "spaceRecoverySettings"

  public var spaceId: Int64
  public var payload: Data

  public init(spaceId: Int64, settings: InlineProtocol.SpaceSettings) throws {
    self.spaceId = spaceId
    payload = try settings.serializedData()
  }
}

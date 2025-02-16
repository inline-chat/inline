import Combine
import GRDB
import GRDBQuery

/// Fetches current user from the database.
public struct CurrentUser: ValueObservationQueryable {
  public static var defaultValue: UserInfo? { nil }

  public func fetch(_ db: Database) throws -> UserInfo? {
    guard let userId = Auth.shared.getCurrentUserId() else { return nil }

    return try User
      .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      .filter(Column("id") == userId)
      .asRequest(of: UserInfo.self)
      .fetchOne(db)
  }

  public init() {}
}

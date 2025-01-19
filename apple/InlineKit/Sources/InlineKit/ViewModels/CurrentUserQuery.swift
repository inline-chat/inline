import Combine
import GRDB
import GRDBQuery

/// Fetches current user from the database.
public struct CurrentUser: ValueObservationQueryable {
  public static var defaultValue: User? { nil }

  public func fetch(_ db: Database) throws -> User? {
    guard let userId = Auth.shared.getCurrentUserId() else { return nil }
    return try User.fetchOne(db, id: userId)
  }

  public init() {}
}

import Auth
import Combine
import GRDB
import Logger
import SwiftUI

@MainActor
public final class ParticipantSearchViewModel: ObservableObject {
  @Published public private(set) var results: [UserInfo] = []

  private let log = Log.scoped("ParticipantSearch")
  private var db: AppDatabase
  var spaceId: Int64?

  public init(db: AppDatabase, spaceId: Int64?) {
    self.db = db
    self.spaceId = spaceId
  }

  public func search(query: String) {
    log.debug("Searching for query: \(query)")
    guard !query.isEmpty else {
      results = []
      return
    }

    Task {
      do {
        if let spaceId {
          log.debug("Using spaceId: \(spaceId)")
          let spaceMembers = try await db.reader.read { db in
            try Member.filter(Column("spaceId") == spaceId)
              .including(
                required: Member.user.forKey("user")
                  .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
              )
              .asRequest(of: UserInfo.self)
              .filter(
                sql: "user.firstName LIKE ? OR user.lastName LIKE ? OR user.email = ? OR user.username = ?",
                arguments: ["%\(query)%", "%\(query)%", query, query]
              )
              .fetchAll(db)
          }

          log.debug("Fetched \(spaceMembers.count) space members")
          results = spaceMembers.sorted(by: {
            $0.user.displayName < $1.user.displayName
          })
        } else {
          results = []
        }
      } catch {
        Log.shared.error("Failed to search space members: \(error)")
        results = []
      }
    }
  }
}

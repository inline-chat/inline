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
  private(set) var searchTask: Task<Void, Never>?
  private var searchToken = UUID()
  var spaceId: Int64?

  public init(db: AppDatabase, spaceId: Int64?) {
    self.db = db
    self.spaceId = spaceId
  }

  deinit {
    searchTask?.cancel()
  }

  public func search(query: String) {
    searchTask?.cancel()
    searchTask = nil
    searchToken = UUID()
    let token = searchToken
    log.debug("Searching for query: \(query)")
    guard !query.isEmpty else {
      results = []
      return
    }

    searchTask = Task { [weak self, db, spaceId] in
      guard !Task.isCancelled else { return }
      do {
        if let spaceId {
          self?.log.debug("Using spaceId: \(spaceId)")
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

          guard !Task.isCancelled, let self, self.searchToken == token else { return }
          self.log.debug("Fetched \(spaceMembers.count) space members")
          self.results = spaceMembers.sorted(by: {
            $0.user.displayName < $1.user.displayName
          })
        } else {
          guard !Task.isCancelled, let self, self.searchToken == token else { return }
          self.results = []
        }
      } catch {
        guard !Task.isCancelled, let self, self.searchToken == token else { return }
        Log.shared.error("Failed to search space members: \(error)")
        self.results = []
      }
    }
  }
}

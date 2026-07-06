import Combine
import Foundation
import GRDB
import Logger

@MainActor
public final class UserGroupDetailsViewModel: ObservableObject {
  @Published public private(set) var group: UserGroup?
  @Published public private(set) var members: [UserGroupMemberInfo] = []
  @Published public private(set) var isLoading = false
  @Published public private(set) var hasLoadedLocalSnapshot = false
  @Published public private(set) var errorMessage: String?

  private let db: AppDatabase
  private let groupId: Int64
  private let spaceId: Int64?
  private let log = Log.scoped("UserGroupDetailsViewModel")

  public init(groupId: Int64, spaceId: Int64?, db: AppDatabase = .shared) {
    self.groupId = groupId
    self.spaceId = spaceId
    self.db = db
  }

  public func refresh() async {
    errorMessage = nil

    do {
      try await loadLocalSnapshot()
      let hasLocalGroup = group != nil

      guard let spaceId else {
        if !hasLocalGroup {
          errorMessage = "User group is unavailable."
        }
        return
      }

      isLoading = !hasLocalGroup
      do {
        try await Api.realtime.send(.getUserGroups(spaceId: spaceId))
        try await loadLocalSnapshot()
        if group == nil {
          errorMessage = "User group is unavailable."
        }
      } catch {
        if group == nil {
          errorMessage = error.localizedDescription
        }
        log.error("Failed to refresh user group details", error: error)
      }
      isLoading = false
    } catch {
      hasLoadedLocalSnapshot = true
      isLoading = false
      errorMessage = error.localizedDescription
      log.error("Failed to load user group details", error: error)
    }
  }

  private func loadLocalSnapshot() async throws {
    let snapshot = try await db.reader.read { db in
      try Self.fetchSnapshot(db, groupId: groupId)
    }

    group = snapshot.group
    members = snapshot.members
    hasLoadedLocalSnapshot = true
  }

  nonisolated private static func fetchSnapshot(_ db: Database, groupId: Int64) throws -> Snapshot {
    let group = try UserGroup.fetchOne(db, id: groupId)
    let members = try fetchMembers(db, groupId: groupId)
    return Snapshot(group: group, members: members)
  }

  nonisolated private static func fetchMembers(_ db: Database, groupId: Int64) throws -> [UserGroupMemberInfo] {
    let rows = try UserGroupMember
      .filter(UserGroupMember.Columns.groupId == groupId)
      .including(
        required: UserGroupMember.user
          .forKey("userInfo")
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )
      .asRequest(of: DetailsUserGroupMemberRow.self)
      .fetchAll(db)

    return rows
      .map { UserGroupMemberInfo(userInfo: $0.userInfo) }
      .sorted { lhs, rhs in
        lhs.userInfo.user.displayName.localizedCaseInsensitiveCompare(rhs.userInfo.user.displayName) == .orderedAscending
      }
  }
}

private struct Snapshot: Sendable {
  var group: UserGroup?
  var members: [UserGroupMemberInfo]
}

private struct DetailsUserGroupMemberRow: Codable, FetchableRecord {
  var member: UserGroupMember
  var userInfo: UserInfo
}

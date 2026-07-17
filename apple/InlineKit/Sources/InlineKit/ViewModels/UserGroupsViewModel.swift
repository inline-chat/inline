import Combine
import Foundation
import GRDB
import Logger

public struct UserGroupMemberInfo: Identifiable, Hashable, Sendable {
  public var userInfo: UserInfo

  public var id: Int64 {
    userInfo.user.id
  }

  public init(userInfo: UserInfo) {
    self.userInfo = userInfo
  }
}

@MainActor
public final class UserGroupsViewModel: ObservableObject {
  public static let maxMembers = 25

  @Published public private(set) var groups: [UserGroup] = []
  @Published public private(set) var members: [FullMemberItem] = []
  @Published public private(set) var groupMembersByGroupId: [Int64: [UserGroupMemberInfo]] = [:]
  @Published public private(set) var isLoading = false
  @Published public private(set) var isMutating = false
  @Published public private(set) var errorMessage: String?

  public var selectableMembers: [FullMemberItem] {
    members.filter { $0.userInfo.user.pendingSetup != true }
  }

  private let db: AppDatabase
  private let spaceId: Int64
  private var groupsCancellable: AnyCancellable?
  private var membersCancellable: AnyCancellable?
  private var didLoad = false
  private let log = Log.scoped("UserGroupsViewModel")

  public init(db: AppDatabase, spaceId: Int64) {
    self.db = db
    self.spaceId = spaceId
    observeGroups()
    observeMembers()
  }

  public func loadIfNeeded() async {
    guard !didLoad else { return }
    didLoad = true
    await refresh()
  }

  public func refresh() async {
    isLoading = true
    errorMessage = nil

    do {
      try await Api.realtime.send(.getUserGroups(spaceId: spaceId))
      try await Api.realtime.send(.getSpaceMembers(spaceId: spaceId))
      isLoading = false
    } catch {
      isLoading = false
      errorMessage = error.localizedDescription
      log.error("Failed to refresh user groups", error: error)
    }
  }

  public func userIds(for group: UserGroup) -> Set<Int64> {
    Set(groupMembersByGroupId[group.id, default: []].map(\.userInfo.user.id))
  }

  public func create(name: String, description: String?, userIds: Set<Int64>) async throws {
    try validate(name: name, userIds: userIds)
    try await mutate {
      try await Api.realtime.send(.createUserGroup(
        spaceId: spaceId,
        name: normalizedName(name),
        description: normalizedDescription(description),
        userIds: normalizedUserIds(userIds)
      ))
    }
  }

  public func update(group: UserGroup, name: String, description: String?, userIds: Set<Int64>) async throws {
    try validate(name: name, userIds: userIds)
    try await mutate {
      try await Api.realtime.send(.updateUserGroup(
        groupId: group.id,
        name: normalizedName(name),
        description: normalizedDescription(description),
        userIds: normalizedUserIds(userIds)
      ))
    }
  }

  public func delete(group: UserGroup) async throws {
    try await mutate {
      try await Api.realtime.send(.deleteUserGroup(groupId: group.id))
    }
  }

  private func observeGroups() {
    db.warnIfInMemoryDatabaseForObservation("UserGroupsViewModel.groups")
    groupsCancellable = ValueObservation
      .tracking { [spaceId] db in
        let groups = try UserGroup
          .filter(UserGroup.Columns.spaceId == spaceId)
          .order(UserGroup.Columns.name.collating(.localizedCaseInsensitiveCompare))
          .fetchAll(db)

        let groupIds = groups.map(\.id)
        let members = try Self.fetchMembers(db, groupIds: groupIds)
        return (groups, members)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Failed to observe user groups", error: error)
          }
        },
        receiveValue: { [weak self] groups, members in
          self?.groups = groups
          self?.groupMembersByGroupId = members
        }
      )
  }

  private func observeMembers() {
    db.warnIfInMemoryDatabaseForObservation("UserGroupsViewModel.members")
    membersCancellable = ValueObservation
      .tracking { [spaceId] db in
        try Member
          .fullMemberQuery()
          .filter(Member.Columns.spaceId == spaceId)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Failed to observe space members for user groups", error: error)
          }
        },
        receiveValue: { [weak self] members in
          self?.members = members
        }
      )
  }

  private func mutate(_ operation: () async throws -> Void) async throws {
    isMutating = true
    errorMessage = nil

    do {
      try await operation()
      isMutating = false
    } catch {
      isMutating = false
      errorMessage = error.localizedDescription
      log.error("Failed to mutate user group", error: error)
      throw error
    }
  }

  private func validate(name: String, userIds: Set<Int64>) throws {
    guard !normalizedName(name).isEmpty else {
      throw UserGroupsViewModelError.emptyName
    }

    guard userIds.count <= Self.maxMembers else {
      throw UserGroupsViewModelError.tooManyMembers(Self.maxMembers)
    }
  }

  nonisolated private static func fetchMembers(
    _ db: Database,
    groupIds: [Int64]
  ) throws -> [Int64: [UserGroupMemberInfo]] {
    guard !groupIds.isEmpty else { return [:] }

    let rows = try UserGroupMember
      .filter(groupIds.contains(UserGroupMember.Columns.groupId))
      .including(
        required: UserGroupMember.user
          .forKey("userInfo")
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )
      .asRequest(of: UserGroupMemberRow.self)
      .fetchAll(db)

    return Dictionary(grouping: rows, by: { $0.member.groupId })
      .mapValues { rows in
        rows
          .map { UserGroupMemberInfo(userInfo: $0.userInfo) }
          .sorted { lhs, rhs in
            lhs.userInfo.user.displayName.localizedCaseInsensitiveCompare(rhs.userInfo.user.displayName) == .orderedAscending
          }
      }
  }
}

public enum UserGroupsViewModelError: LocalizedError, Equatable {
  case emptyName
  case tooManyMembers(Int)

  public var errorDescription: String? {
    switch self {
      case .emptyName:
        "Group name is required."
      case let .tooManyMembers(max):
        "User groups can include up to \(max) people."
    }
  }
}

private struct UserGroupMemberRow: Codable, FetchableRecord {
  var member: UserGroupMember
  var userInfo: UserInfo
}

private func normalizedName(_ name: String) -> String {
  name.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedDescription(_ description: String?) -> String? {
  let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let trimmed, !trimmed.isEmpty else { return nil }
  return trimmed
}

private func normalizedUserIds(_ userIds: Set<Int64>) -> [Int64] {
  userIds.sorted()
}

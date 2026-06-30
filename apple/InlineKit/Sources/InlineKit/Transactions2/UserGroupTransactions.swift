import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetUserGroupsTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetUserGroups")

  public var method: InlineProtocol.Method = .getUserGroups
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
  }

  public init(spaceId: Int64) {
    context = Context(spaceId: spaceId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getUserGroups(.with { $0.spaceID = context.spaceId })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getUserGroups(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        for user in response.users {
          _ = try User.save(db, user: user)
        }

        let ids = response.groups.map(\.id)
        if !ids.isEmpty {
          try UserGroup
            .filter(UserGroup.Columns.spaceId == context.spaceId)
            .filter(!ids.contains(UserGroup.Columns.id))
            .deleteAll(db)
        } else {
          try UserGroup
            .filter(UserGroup.Columns.spaceId == context.spaceId)
            .deleteAll(db)
        }

        for group in response.groups {
          try UserGroup.save(db, from: group)
        }
      }
    } catch {
      log.error("Failed to save user groups", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public struct CreateUserGroupTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/CreateUserGroup")

  public var method: InlineProtocol.Method = .createUserGroup
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
    let name: String
    let description: String?
    let userIds: [Int64]
  }

  public init(spaceId: Int64, name: String, description: String?, userIds: [Int64]) {
    context = Context(spaceId: spaceId, name: name, description: description, userIds: userIds)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createUserGroup(.with {
      $0.spaceID = context.spaceId
      $0.name = context.name
      if let description = normalizedDescription(context.description) {
        $0.description_p = description
      }
      $0.userIds = context.userIds
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .createUserGroup(response) = result, response.hasGroup else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try UserGroup.save(db, from: response.group)
      }
    } catch {
      log.error("Failed to save created user group", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public struct UpdateUserGroupTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/UpdateUserGroup")

  public var method: InlineProtocol.Method = .updateUserGroup
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let groupId: Int64
    let name: String
    let description: String?
    let userIds: [Int64]
  }

  public init(groupId: Int64, name: String, description: String?, userIds: [Int64]) {
    context = Context(groupId: groupId, name: name, description: description, userIds: userIds)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateUserGroup(.with {
      $0.groupID = context.groupId
      $0.name = context.name
      if let description = normalizedDescription(context.description) {
        $0.description_p = description
      }
      $0.userIds = context.userIds
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateUserGroup(response) = result, response.hasGroup else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try UserGroup.save(db, from: response.group)
      }
    } catch {
      log.error("Failed to save updated user group", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public struct DeleteUserGroupTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/DeleteUserGroup")

  public var method: InlineProtocol.Method = .deleteUserGroup
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let groupId: Int64
  }

  public init(groupId: Int64) {
    context = Context(groupId: groupId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteUserGroup(.with { $0.groupID = context.groupId })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .deleteUserGroup = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try UserGroup.delete(db, id: context.groupId)
      }
    } catch {
      log.error("Failed to delete user group locally", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == GetUserGroupsTransaction {
  static func getUserGroups(spaceId: Int64) -> GetUserGroupsTransaction {
    GetUserGroupsTransaction(spaceId: spaceId)
  }
}

public extension Transaction2 where Self == CreateUserGroupTransaction {
  static func createUserGroup(
    spaceId: Int64,
    name: String,
    description: String?,
    userIds: [Int64]
  ) -> CreateUserGroupTransaction {
    CreateUserGroupTransaction(spaceId: spaceId, name: name, description: description, userIds: userIds)
  }
}

public extension Transaction2 where Self == UpdateUserGroupTransaction {
  static func updateUserGroup(
    groupId: Int64,
    name: String,
    description: String?,
    userIds: [Int64]
  ) -> UpdateUserGroupTransaction {
    UpdateUserGroupTransaction(groupId: groupId, name: name, description: description, userIds: userIds)
  }
}

public extension Transaction2 where Self == DeleteUserGroupTransaction {
  static func deleteUserGroup(groupId: Int64) -> DeleteUserGroupTransaction {
    DeleteUserGroupTransaction(groupId: groupId)
  }
}

private func normalizedDescription(_ description: String?) -> String? {
  let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let trimmed, !trimmed.isEmpty else { return nil }
  return trimmed
}

import Combine
import GRDB
import Logger
import SwiftUI

@MainActor
public final class ReplyThreadUsersViewModel: ObservableObject {
  @Published public private(set) var users: [UserInfo] = []

  private let db: AppDatabase
  private let log = Log.scoped("ReplyThreadUsersViewModel")
  private var userIds: [Int64]
  private var cancellable: AnyCancellable?

  public init(userIds: [Int64] = [], db: AppDatabase? = nil) {
    self.db = db ?? AppDatabase.shared
    self.userIds = Self.deduplicated(userIds)
    self.users = Self.loadUsers(userIds: self.userIds, db: self.db, log: log)
    observe()
  }

  public func update(userIds: [Int64]) {
    let deduplicatedIds = Self.deduplicated(userIds)
    guard deduplicatedIds != self.userIds else { return }
    self.userIds = deduplicatedIds
    self.users = Self.loadUsers(userIds: deduplicatedIds, db: db, log: log)
    observe()
  }

  private func observe() {
    guard userIds.isEmpty == false else {
      cancellable = nil
      users = []
      return
    }

    let userIds = self.userIds
    db.warnIfInMemoryDatabaseForObservation("ReplyThreadUsersViewModel.users")
    cancellable = ValueObservation
      .tracking { db in
        let userInfos = try User
          .filter(userIds.contains(User.Columns.id))
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
          .asRequest(of: UserInfo.self)
          .fetchAll(db)

        let usersById = Dictionary(uniqueKeysWithValues: userInfos.map { ($0.id, $0) })
        return userIds.compactMap { usersById[$0] }
      }
      .publisher(in: db.reader, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Failed to observe reply-thread users: \(completion)")
        },
        receiveValue: { [weak self] users in
          self?.users = users
        }
      )
  }

  private static func loadUsers(userIds: [Int64], db: AppDatabase, log: Log) -> [UserInfo] {
    guard userIds.isEmpty == false else { return [] }

    do {
      return try db.reader.read { db in
        let userInfos = try User
          .filter(userIds.contains(User.Columns.id))
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
          .asRequest(of: UserInfo.self)
          .fetchAll(db)

        let usersById = Dictionary(uniqueKeysWithValues: userInfos.map { ($0.id, $0) })
        return userIds.compactMap { usersById[$0] }
      }
    } catch {
      log.error("Failed to bootstrap reply-thread users", error: error)
      return []
    }
  }

  private static func deduplicated(_ userIds: [Int64]) -> [Int64] {
    var seen = Set<Int64>()
    return userIds.filter { seen.insert($0).inserted }
  }
}

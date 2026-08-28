import Auth
import Foundation
import GRDB
import Logger
import RealtimeV2

public enum ReservedChatIDPoolError: Error {
  case invalidResponse
  case emptyReservations
}

public actor ReservedChatIDPool {
  public static let shared = ReservedChatIDPool()

  private let lowWatermark = 1
  private let targetCount = 3
  private let log = Log.scoped("ReservedChatIDPool")

  public init() {}

  public func consumeCached(realtimeV2: RealtimeV2) async -> Int64? {
    do {
      let mutationToken = try Auth.shared.handle.beginAccountMutation()
      try await pruneExpiredReservations(mutationToken: mutationToken)

      let reservedChatId = try await popOldestReservation(mutationToken: mutationToken)
      Task {
        try? await self.refillIfNeeded(realtimeV2: realtimeV2)
      }

      return reservedChatId
    } catch {
      log.error("Failed to consume cached reserved chat id", error: error)
      Task {
        try? await self.refillIfNeeded(realtimeV2: realtimeV2)
      }
      return nil
    }
  }

  public func refillIfNeeded(realtimeV2: RealtimeV2) async throws {
    let mutationToken = try Auth.shared.handle.beginAccountMutation()
    try await pruneExpiredReservations(mutationToken: mutationToken)

    let currentCount = try await AppDatabase.shared.reader.read { db in
      try ReservedChatID.fetchCount(db)
    }

    guard currentCount < lowWatermark else { return }
    _ = try await reserveAndPersist(
      count: targetCount - currentCount,
      realtimeV2: realtimeV2,
      mutationToken: mutationToken
    )
  }
}

private extension ReservedChatIDPool {
  func reserveAndPersist(
    count: Int,
    realtimeV2: RealtimeV2,
    mutationToken: AuthAccountMutationToken
  ) async throws -> [ReservedChatID] {
    guard count > 0 else { return [] }

    try Auth.shared.handle.validateAccountMutation(mutationToken)
    let result = try await realtimeV2.send(.reserveChatIds(count: Int32(count)))
    guard case let .reserveChatIds(response) = result else {
      throw ReservedChatIDPoolError.invalidResponse
    }

    let now = Date()
    let reservations = response.reservations.map {
      ReservedChatID(
        chatId: $0.chatID,
        expiresAt: Date(timeIntervalSince1970: Double($0.expiresAt)),
        createdAt: now
      )
    }

    guard !reservations.isEmpty else {
      throw ReservedChatIDPoolError.emptyReservations
    }

    try await AppDatabase.shared.dbWriter.write { db in
      try Auth.shared.handle.validateAccountMutation(mutationToken)
      for reservation in reservations {
        try reservation.save(db)
      }
    }

    log.debug("Stored \(reservations.count) reserved chat ids")
    return reservations
  }

  func popOldestReservation(mutationToken: AuthAccountMutationToken) async throws -> Int64? {
    try await AppDatabase.shared.dbWriter.write { db in
      try Auth.shared.handle.validateAccountMutation(mutationToken)
      guard let reservation = try ReservedChatID
        .order(ReservedChatID.Columns.createdAt.asc)
        .fetchOne(db)
      else {
        return nil
      }

      try reservation.delete(db)
      return reservation.chatId
    }
  }

  func pruneExpiredReservations(mutationToken: AuthAccountMutationToken) async throws {
    _ = try await AppDatabase.shared.dbWriter.write { db in
      try Auth.shared.handle.validateAccountMutation(mutationToken)
      try ReservedChatID
        .filter(ReservedChatID.Columns.expiresAt <= Date())
        .deleteAll(db)
    }
  }
}

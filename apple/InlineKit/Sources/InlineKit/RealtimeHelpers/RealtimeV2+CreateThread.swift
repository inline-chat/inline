import Foundation
import Logger
import RealtimeV2

private let createThreadLog = Log.scoped("RealtimeV2.CreateThread")
private enum CreateThreadLocalError: Error {
  case invalidResponse
}

struct CreateThreadExecutor {
  let reservedChatIdProvider: @Sendable () async throws -> Int64?
  let queuedCreateWithReservation: @Sendable (Int64) async throws -> Int64
  let directCreate: @Sendable () async throws -> Int64

  @discardableResult
  func create() async throws -> Int64 {
    do {
      if let reservedChatId = try await reservedChatIdProvider() {
        return try await queuedCreateWithReservation(reservedChatId)
      }
    } catch {
      createThreadLog.error("Failed to acquire reserved chat id; falling back to direct create", error: error)
    }

    return try await directCreate()
  }
}

public extension RealtimeV2 {
  @discardableResult
  func createThreadLocally(
    title: String,
    emoji: String?,
    isPublic: Bool,
    spaceId: Int64?,
    participants: [Int64]
  ) async throws -> Int64 {
    let executor = CreateThreadExecutor(
      reservedChatIdProvider: {
        await ReservedChatIDPool.shared.consumeCached(realtimeV2: self)
      },
      queuedCreateWithReservation: { reservedChatId in
        _ = await self.sendQueued(
          .createChat(
            title: title,
            emoji: emoji,
            isPublic: isPublic,
            spaceId: spaceId,
            participants: participants,
            reservedChatId: reservedChatId
          )
        )
        return reservedChatId
      },
      directCreate: {
        let result = try await self.send(
          .createChat(
            title: title,
            emoji: emoji,
            isPublic: isPublic,
            spaceId: spaceId,
            participants: participants
          )
        )

        guard case let .createChat(response) = result else {
          throw CreateThreadLocalError.invalidResponse
        }

        return response.chat.id
      }
    )

    return try await executor.create()
  }
}

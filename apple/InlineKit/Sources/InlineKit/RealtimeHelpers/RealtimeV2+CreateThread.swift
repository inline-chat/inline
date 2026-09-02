import Foundation
import InlineProtocol
import Logger
import RealtimeV2

private let createThreadLog = Log.scoped("RealtimeV2.CreateThread")
private enum CreateThreadLocalError: Error {
  case invalidResponse
  case queueAdmissionFailed
}

struct CreateThreadExecutor {
  let reservedChatIdProvider: @Sendable () async throws -> Int64?
  let queuedCreateWithReservation: @Sendable (Int64) async throws -> Int64
  let directCreate: @Sendable () async throws -> Int64

  @discardableResult
  func create() async throws -> Int64 {
    let reservedChatId: Int64?
    do {
      reservedChatId = try await reservedChatIdProvider()
    } catch {
      createThreadLog.error("Failed to acquire reserved chat id; falling back to direct create", error: error)
      return try await directCreate()
    }

    if let reservedChatId {
      // Once consumed, a reservation has exactly one creation owner. Do not
      // fall back to another create if local admission fails: that can produce
      // two threads when the first request is merely uncertain.
      return try await queuedCreateWithReservation(reservedChatId)
    }

    return try await directCreate()
  }
}

public extension RealtimeV2 {
  @discardableResult
  func createThreadLocally(
    title: String?,
    placeholderTitle: String? = nil,
    emoji: String?,
    isPublic: Bool,
    spaceId: Int64?,
    participants: [Int64],
    agentContext: InlineProtocol.AgentThreadContext? = nil
  ) async throws -> Int64 {
    let executor = CreateThreadExecutor(
      reservedChatIdProvider: {
        await ReservedChatIDPool.shared.consumeCached(realtimeV2: self)
      },
      queuedCreateWithReservation: { reservedChatId in
        guard await self.sendQueuedIfAccepted(
          .createChat(
            title: title,
            placeholderTitle: placeholderTitle,
            emoji: emoji,
            isPublic: isPublic,
            spaceId: spaceId,
            participants: participants,
            reservedChatId: reservedChatId,
            agentContext: agentContext
          )
        ) != nil else {
          throw CreateThreadLocalError.queueAdmissionFailed
        }

        return reservedChatId
      },
      directCreate: {
        let result = try await self.send(
          .createChat(
            title: title,
            placeholderTitle: placeholderTitle,
            emoji: emoji,
            isPublic: isPublic,
            spaceId: spaceId,
            participants: participants,
            agentContext: agentContext
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

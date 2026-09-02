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

  private struct ScheduledRefill {
    let id: UInt64
    let task: Task<Void, Never>
  }

  private let lowWatermark = 1
  private let targetCount = 3
  private let log = Log.scoped("ReservedChatIDPool")
  private var nextRefillID: UInt64 = 0
  private var scheduledRefill: ScheduledRefill?
  private var activeOperations = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private var isPaused = false
  private var isPreparingForTermination = false

  public init() {}

  public func consumeCached(realtimeV2: RealtimeV2) async -> Int64? {
    do {
      try beginOperation()
      defer { endOperation() }
      let mutationToken = try Auth.shared.handle.beginAccountMutation()
      try checkOperation(mutationToken)
      try await pruneExpiredReservations(mutationToken: mutationToken)
      try checkOperation(mutationToken)
      let reservedChatId = try await popOldestReservation(mutationToken: mutationToken)
      scheduleRefill(realtimeV2: realtimeV2)
      return reservedChatId
    } catch is CancellationError {
      return nil
    } catch {
      log.error("Failed to consume cached reserved chat id", error: error)
      scheduleRefill(realtimeV2: realtimeV2)
      return nil
    }
  }

  /// Coalesces best-effort refills so teardown has one task it can cancel and drain.
  public func scheduleRefill(realtimeV2: RealtimeV2) {
    guard !isPaused, !isPreparingForTermination, scheduledRefill == nil else { return }
    nextRefillID &+= 1
    let id = nextRefillID
    let task = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      await self.runScheduledRefill(id: id, realtimeV2: realtimeV2)
    }
    scheduledRefill = ScheduledRefill(id: id, task: task)
  }

  /// Temporarily prevents new pool work while local data is replaced in place.
  public func pauseAndDrain() async {
    guard !isPreparingForTermination else { return }
    isPaused = true
    await cancelScheduledRefill()
    await waitForOperationsToFinish()
  }

  public func resume(realtimeV2: RealtimeV2) {
    guard !isPreparingForTermination else { return }
    isPaused = false
    scheduleRefill(realtimeV2: realtimeV2)
  }

  /// Logout already closes auth admission synchronously; this drains work admitted before it.
  public func drainForAccountTransition() async {
    await cancelScheduledRefill()
    await waitForOperationsToFinish()
  }

  /// Terminal process teardown. A new process owns future refills.
  public func prepareForTermination() async {
    isPreparingForTermination = true
    isPaused = true
    await cancelScheduledRefill()
    await waitForOperationsToFinish()
  }
}

private extension ReservedChatIDPool {
  func runScheduledRefill(id: UInt64, realtimeV2: RealtimeV2) async {
    do {
      try await refillIfNeeded(realtimeV2: realtimeV2)
    } catch is CancellationError {
      // Expected during logout, local-data replacement, or process teardown.
    } catch {
      log.error("Failed to refill reserved chat ids", error: error)
    }
    if scheduledRefill?.id == id {
      scheduledRefill = nil
    }
  }

  func cancelScheduledRefill() async {
    guard let refill = scheduledRefill else { return }
    refill.task.cancel()
    await refill.task.value
    if scheduledRefill?.id == refill.id {
      scheduledRefill = nil
    }
  }

  func beginOperation() throws {
    try Task.checkCancellation()
    guard !isPaused, !isPreparingForTermination else { throw CancellationError() }
    activeOperations += 1
  }

  func endOperation() {
    precondition(activeOperations > 0)
    activeOperations -= 1
    guard activeOperations == 0 else { return }
    let waiters = drainWaiters
    drainWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func waitForOperationsToFinish() async {
    guard activeOperations > 0 else { return }
    await withCheckedContinuation { continuation in
      drainWaiters.append(continuation)
    }
  }

  func checkOperation(_ mutationToken: AuthAccountMutationToken) throws {
    try Task.checkCancellation()
    guard !isPaused, !isPreparingForTermination else { throw CancellationError() }
    try Auth.shared.handle.validateAccountMutation(mutationToken)
  }

  func refillIfNeeded(realtimeV2: RealtimeV2) async throws {
    try beginOperation()
    defer { endOperation() }
    let mutationToken = try Auth.shared.handle.beginAccountMutation()
    try checkOperation(mutationToken)
    try await pruneExpiredReservations(mutationToken: mutationToken)
    try checkOperation(mutationToken)
    let currentCount = try await AppDatabase.shared.reader.read { db in
      try Auth.shared.handle.validateAccountMutation(mutationToken)
      return try ReservedChatID.fetchCount(db)
    }
    try checkOperation(mutationToken)
    guard currentCount < lowWatermark else { return }
    _ = try await reserveAndPersist(
      count: targetCount - currentCount,
      realtimeV2: realtimeV2,
      mutationToken: mutationToken
    )
  }

  func reserveAndPersist(
    count: Int,
    realtimeV2: RealtimeV2,
    mutationToken: AuthAccountMutationToken
  ) async throws -> [ReservedChatID] {
    guard count > 0 else { return [] }

    try checkOperation(mutationToken)
    let result = try await realtimeV2.send(.reserveChatIds(count: Int32(count)))
    try checkOperation(mutationToken)
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

    try checkOperation(mutationToken)
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
    try checkOperation(mutationToken)
    return try await AppDatabase.shared.dbWriter.write { db in
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
    try checkOperation(mutationToken)
    _ = try await AppDatabase.shared.dbWriter.write { db in
      try Auth.shared.handle.validateAccountMutation(mutationToken)
      try ReservedChatID
        .filter(ReservedChatID.Columns.expiresAt <= Date())
        .deleteAll(db)
    }
  }
}

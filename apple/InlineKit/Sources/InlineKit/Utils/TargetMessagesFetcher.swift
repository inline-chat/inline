import Foundation
import GRDB
import Logger

public actor TargetMessagesFetcher {
  public static let shared = TargetMessagesFetcher()

  public typealias MissingMessageIDsProvider = @Sendable (_ chatId: Int64, _ messageIds: Set<Int64>) async throws ->
    Set<Int64>
  public typealias FetchMessagesOperation = @Sendable (_ peer: Peer, _ messageIds: [Int64]) async throws -> Void

  private struct FetchTarget: Hashable, Sendable {
    let peer: Peer
    let chatId: Int64
  }

  private struct TargetState {
    var queuedIds: Set<Int64> = []
    var inFlightIds: Set<Int64> = []
    var resolvingIds: Set<Int64> = []
    var runnerTask: Task<Void, Never>?
  }

  private let log = Log.scoped("TargetMessagesFetcher")
  private let maxBatchSize = 200
  private let resolveMissingIds: MissingMessageIDsProvider
  private let fetchMessages: FetchMessagesOperation

  private var targets: [FetchTarget: TargetState] = [:]

  public init() {
    resolveMissingIds = TargetMessagesFetcher.defaultResolveMissingIds
    fetchMessages = TargetMessagesFetcher.defaultFetchMessages
  }

  init(
    resolveMissingIds: @escaping MissingMessageIDsProvider,
    fetchMessages: @escaping FetchMessagesOperation
  ) {
    self.resolveMissingIds = resolveMissingIds
    self.fetchMessages = fetchMessages
  }

  public func ensureCached(peer: Peer, chatId: Int64, messageIds: [Int64]) async {
    let requestedIds = Set(messageIds.filter { $0 > 0 })
    guard !requestedIds.isEmpty else { return }

    let target = FetchTarget(peer: peer, chatId: chatId)
    let idsToResolve = beginResolving(target: target, messageIds: requestedIds)
    guard !idsToResolve.isEmpty else { return }

    let missingIds: Set<Int64>
    do {
      missingIds = try await resolveMissingIds(chatId, idsToResolve)
    } catch is CancellationError {
      finishResolving(target: target, messageIds: idsToResolve)
      return
    } catch {
      log.error("Failed to check cached target messages", error: error)
      missingIds = idsToResolve
    }

    finishResolving(target: target, messageIds: idsToResolve)
    guard !missingIds.isEmpty else { return }

    enqueue(target: target, messageIds: missingIds)
  }

  private static func defaultResolveMissingIds(chatId: Int64, messageIds: Set<Int64>) async throws -> Set<Int64> {
    let ids = Array(messageIds)
    guard !ids.isEmpty else { return [] }

    let existingMessages = try await AppDatabase.shared.dbWriter.read { db in
      try Message
        .filter(Message.Columns.chatId == chatId)
        .filter(ids.contains(Message.Columns.messageId))
        .fetchAll(db)
    }

    let existingIds = Set(existingMessages.map(\.messageId))
    return messageIds.subtracting(existingIds)
  }

  private static func defaultFetchMessages(peer: Peer, messageIds: [Int64]) async throws {
    _ = try await Api.realtime.send(.getMessages(peer: peer, messageIds: messageIds))
  }

  private func enqueue(target: FetchTarget, messageIds: Set<Int64>) {
    var state = targets[target] ?? TargetState()
    let deduped = messageIds
      .subtracting(state.resolvingIds)
      .subtracting(state.inFlightIds)
      .subtracting(state.queuedIds)
    guard !deduped.isEmpty else { return }

    state.queuedIds.formUnion(deduped)
    let shouldStartRunner = state.runnerTask == nil

    if shouldStartRunner {
      state.runnerTask = Task { [target] in
        await self.runQueue(for: target)
      }
    }

    targets[target] = state
  }

  private func beginResolving(target: FetchTarget, messageIds: Set<Int64>) -> Set<Int64> {
    var state = targets[target] ?? TargetState()
    let deduped = messageIds
      .subtracting(state.resolvingIds)
      .subtracting(state.inFlightIds)
      .subtracting(state.queuedIds)
    guard !deduped.isEmpty else { return [] }

    state.resolvingIds.formUnion(deduped)
    targets[target] = state
    return deduped
  }

  private func finishResolving(target: FetchTarget, messageIds: Set<Int64>) {
    guard var state = targets[target] else { return }

    state.resolvingIds.subtract(messageIds)
    save(target: target, state: state)
  }

  private func save(target: FetchTarget, state: TargetState) {
    if state.queuedIds.isEmpty, state.inFlightIds.isEmpty, state.resolvingIds.isEmpty, state.runnerTask == nil {
      targets.removeValue(forKey: target)
      return
    }

    targets[target] = state
  }

  private func runQueue(for target: FetchTarget) async {
    while true {
      guard var state = targets[target] else { return }

      let batchIds = Array(state.queuedIds.prefix(maxBatchSize))
      if batchIds.isEmpty {
        state.runnerTask = nil
        save(target: target, state: state)
        return
      }

      let batchSet = Set(batchIds)
      state.queuedIds.subtract(batchSet)
      state.inFlightIds.formUnion(batchSet)
      targets[target] = state

      do {
        try await fetchMessages(target.peer, batchIds.sorted())
      } catch {
        log.error("Failed to fetch target messages for \(target.peer.toString())", error: error)
      }

      guard var updated = targets[target] else { continue }
      updated.inFlightIds.subtract(batchSet)
      targets[target] = updated
    }
  }
}

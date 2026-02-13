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

    let missingIds: Set<Int64>
    do {
      missingIds = try await resolveMissingIds(chatId, requestedIds)
    } catch {
      log.error("Failed to check cached target messages", error: error)
      missingIds = requestedIds
    }
    guard !missingIds.isEmpty else { return }

    enqueue(target: FetchTarget(peer: peer, chatId: chatId), messageIds: missingIds)
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
    let deduped = messageIds.subtracting(state.inFlightIds).subtracting(state.queuedIds)
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

  private func runQueue(for target: FetchTarget) async {
    while true {
      guard var state = targets[target] else { return }

      let batchIds = Array(state.queuedIds.prefix(maxBatchSize))
      if batchIds.isEmpty {
        state.runnerTask = nil
        if state.inFlightIds.isEmpty {
          targets.removeValue(forKey: target)
        } else {
          targets[target] = state
        }
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

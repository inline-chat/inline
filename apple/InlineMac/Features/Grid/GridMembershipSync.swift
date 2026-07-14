import Foundation
import InlineProtocol
import Logger

struct GridMembershipOperation: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case create
    case join(roomID: Int64)
    case leave(roomID: Int64)
  }

  let kind: Kind
  let spaceID: Int64
  let accessRevision: Int
  let revision: Int
  let startedAt: Date
}

enum GridMembershipSyncEvent: Sendable {
  case created(GridMembershipOperation, GridRoomMutationResult)
  case joined(GridMembershipOperation, GridRoomMutationResult)
  case left(GridMembershipOperation, [InlineProtocol.Grid])
  case failed(GridMembershipOperation, message: String)
}

/// The sole remote executor for Grid avatar membership changes.
///
/// The UI applies product state optimistically, then submits operations here.
/// A single retained worker preserves create/join/leave order at the server even
/// during rapid interaction. Events carry revisions so the room service can
/// ignore responses superseded by newer local intent without losing wire order.
@MainActor
final class GridMembershipSync {
  private struct QueuedOperation {
    let generation: Int
    let operation: GridMembershipOperation
  }

  private let api: GridRoomAPI
  private let log = Log.scoped("GridMembershipSync")
  private var generation = 0
  private var queue: [QueuedOperation] = []
  private var workerTask: Task<Void, Never>?
  private var workerGeneration: Int?
  private var subscribers: [UUID: AsyncStream<GridMembershipSyncEvent>.Continuation] = [:]

  init(api: GridRoomAPI) {
    self.api = api
  }

  deinit {
    workerTask?.cancel()
    subscribers.values.forEach { $0.finish() }
  }

  func subscribe() -> AsyncStream<GridMembershipSyncEvent> {
    let id = UUID()
    let stream = AsyncStream.makeStream(
      of: GridMembershipSyncEvent.self,
      // Results are revisioned and every success carries authoritative Grid
      // state. A newer result supersedes an older event for a stalled consumer.
      bufferingPolicy: .bufferingNewest(64)
    )
    stream.continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
    }
    subscribers[id] = stream.continuation
    return stream.stream
  }

  func submit(_ operation: GridMembershipOperation) {
    queue.append(QueuedOperation(generation: generation, operation: operation))
    startIfNeeded()
  }

  /// Invalidates queued work during logout. An in-flight RPC may still finish
  /// at the transport, but its event is discarded and it cannot retain the
  /// worker slot needed by a later authenticated generation.
  func reset() {
    generation &+= 1
    queue.removeAll()
    workerTask?.cancel()
    workerTask = nil
    workerGeneration = nil
  }

  private func startIfNeeded() {
    guard workerTask == nil, !queue.isEmpty else { return }
    let workerGeneration = generation
    self.workerGeneration = workerGeneration
    workerTask = Task { [weak self] in
      await self?.run(workerGeneration: workerGeneration)
    }
  }

  private func run(workerGeneration: Int) async {
    while !Task.isCancelled, generation == workerGeneration, !queue.isEmpty {
      let queued = queue.removeFirst()
      guard queued.generation == workerGeneration else { continue }
      let operation = queued.operation
      do {
        let event: GridMembershipSyncEvent = switch operation.kind {
        case .create:
          .created(operation, try await api.createRoom(spaceID: operation.spaceID))
        case let .join(roomID):
          .joined(operation, try await api.joinRoom(roomID: roomID))
        case let .leave(roomID):
          .left(operation, try await api.leaveRoom(roomID: roomID))
        }
        guard !Task.isCancelled, workerGeneration == generation else { continue }
        broadcast(event)
      } catch {
        guard !Task.isCancelled, workerGeneration == generation else { continue }
        log.error(
          "GRID_TRACE phase=membership_rpc_failed revision=\(operation.revision)",
          error: error
        )
        broadcast(.failed(operation, message: String(describing: error)))
      }
    }
    guard self.workerGeneration == workerGeneration else { return }
    workerTask = nil
    self.workerGeneration = nil
    startIfNeeded()
  }

  private func broadcast(_ event: GridMembershipSyncEvent) {
    subscribers.values.forEach { $0.yield(event) }
  }
}

import Foundation
import InlineProtocol
import RealtimeV2

enum GridRoomLifecycleEvent: Sendable {
  case grid(GridEvent)
  case realtimeConnection(RealtimeConnectionState)
  case network(GridNetworkPathSnapshot)
  case heartbeat
}

/// Collects external lifecycle sources without owning Grid product state.
/// Every subscriber receives its own watch/event stream.
@MainActor
final class GridRoomLifecycle {
  private let realtime: RealtimeV2
  private let network: GridNetworkMonitor
  private var sourceTasks: [Task<Void, Never>] = []
  private var subscribers: [UUID: AsyncStream<GridRoomLifecycleEvent>.Continuation] = [:]
  private var started = false

  init(realtime: RealtimeV2, network: GridNetworkMonitor) {
    self.realtime = realtime
    self.network = network
  }

  deinit {
    sourceTasks.forEach { $0.cancel() }
    subscribers.values.forEach { $0.finish() }
  }

  func subscribe() -> AsyncStream<GridRoomLifecycleEvent> {
    startIfNeeded()
    let id = UUID()
    let stream = AsyncStream.makeStream(
      of: GridRoomLifecycleEvent.self,
      // Lifecycle edges only trigger authoritative refetch/reconciliation;
      // retain a bounded recent window for a temporarily suspended observer.
      bufferingPolicy: .bufferingNewest(64)
    )
    stream.continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
    }
    subscribers[id] = stream.continuation
    return stream.stream
  }

  private func startIfNeeded() {
    guard !started else { return }
    started = true
    sourceTasks = [
      Task { [weak self, realtime] in
        for await event in await realtime.gridEvents() {
          guard !Task.isCancelled else { return }
          self?.broadcast(.grid(event))
        }
      },
      Task { [weak self, realtime] in
        for await state in await realtime.connectionStates() {
          guard !Task.isCancelled else { return }
          self?.broadcast(.realtimeConnection(state))
        }
      },
      Task { [weak self, network] in
        for await snapshot in network.subscribe() {
          guard !Task.isCancelled else { return }
          self?.broadcast(.network(snapshot))
        }
      },
      Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(30))
          guard !Task.isCancelled else { return }
          self?.broadcast(.heartbeat)
        }
      },
    ]
  }

  private func broadcast(_ event: GridRoomLifecycleEvent) {
    subscribers.values.forEach { $0.yield(event) }
  }
}

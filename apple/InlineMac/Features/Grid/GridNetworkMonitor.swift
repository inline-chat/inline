import Foundation
import Network

struct GridNetworkPathSnapshot: Equatable, Sendable {
  let available: Bool
  let usesWiFi: Bool
  let usesWiredEthernet: Bool
  let usesCellular: Bool
  let constrained: Bool
  let expensive: Bool

  init(path: NWPath) {
    available = path.status == .satisfied
    usesWiFi = path.usesInterfaceType(.wifi)
    usesWiredEthernet = path.usesInterfaceType(.wiredEthernet)
    usesCellular = path.usesInterfaceType(.cellular)
    constrained = path.isConstrained
    expensive = path.isExpensive
  }

  var interfaceDescription: String {
    if usesWiredEthernet { return "ethernet" }
    if usesWiFi { return "wifi" }
    if usesCellular { return "cellular" }
    return "other"
  }
}

/// Owns `NWPathMonitor` and vends independent watch streams. Consumers never
/// compete for values from one shared `AsyncStream` iterator.
@MainActor
final class GridNetworkMonitor {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "Grid.NetworkMonitor")
  private var subscribers: [UUID: AsyncStream<GridNetworkPathSnapshot>.Continuation] = [:]
  private var latest: GridNetworkPathSnapshot?

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let snapshot = GridNetworkPathSnapshot(path: path)
      Task { @MainActor [weak self] in
        self?.broadcast(snapshot)
      }
    }
    monitor.start(queue: queue)
  }

  deinit {
    monitor.cancel()
    subscribers.values.forEach { $0.finish() }
  }

  func subscribe() -> AsyncStream<GridNetworkPathSnapshot> {
    let id = UUID()
    let stream = AsyncStream.makeStream(
      of: GridNetworkPathSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    stream.continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
    }
    subscribers[id] = stream.continuation
    if let latest {
      stream.continuation.yield(latest)
    }
    return stream.stream
  }

  private func broadcast(_ snapshot: GridNetworkPathSnapshot) {
    // Realtime and LiveKit observe their own socket/path transitions, including
    // same-interface Wi-Fi changes. Grid only needs a separate recovery epoch
    // when this coarse availability/interface state actually changes; emitting
    // identical callbacks can otherwise create a refresh/retry feedback loop.
    guard latest != snapshot else { return }
    latest = snapshot
    subscribers.values.forEach { $0.yield(snapshot) }
  }
}

import Combine
import Foundation

public enum RealtimeConnectionDisplayPhase: Sendable {
  case coldStart
  case reconnect
}

public struct RealtimeConnectionDisplayPolicy: Sendable {
  public let coldStartDelaySeconds: TimeInterval
  public let reconnectDelaySeconds: TimeInterval
  public let hideDelaySeconds: TimeInterval

  public init(
    coldStartDelaySeconds: TimeInterval,
    reconnectDelaySeconds: TimeInterval,
    hideDelaySeconds: TimeInterval
  ) {
    self.coldStartDelaySeconds = coldStartDelaySeconds
    self.reconnectDelaySeconds = reconnectDelaySeconds
    self.hideDelaySeconds = hideDelaySeconds
  }

  public static let `default` = RealtimeConnectionDisplayPolicy(
    coldStartDelaySeconds: 2,
    reconnectDelaySeconds: 4,
    hideDelaySeconds: 1
  )

  public func showDelaySeconds(for phase: RealtimeConnectionDisplayPhase) -> TimeInterval {
    switch phase {
    case .coldStart:
      coldStartDelaySeconds
    case .reconnect:
      reconnectDelaySeconds
    }
  }
}

/// An ObservableObject class that represents the state of the Realtime connection for usage in SwiftUI views
public class RealtimeState: ObservableObject, @unchecked Sendable {
  // Private properties
  private weak var realtime: RealtimeV2?
  private var task: Task<Void, Never>?
  private var showTask: Task<Void, Never>?
  private var hideTask: Task<Void, Never>?
  /// UI-facing display policy. This only controls `displayedConnectionState`;
  /// it never feeds back into the engine's main `connectionState`.
  private let displayPolicy: RealtimeConnectionDisplayPolicy
  private var didReachConnectedState = false

  // Published properties
  @Published public var connectionState: RealtimeConnectionState = .connecting
  @Published public private(set) var displayedConnectionState: RealtimeConnectionState?

  // Publishers
  public var connectionStatePublisher: PassthroughSubject<RealtimeConnectionState, Never> = .init()
  public var displayedConnectionStatePublisher: PassthroughSubject<RealtimeConnectionState?, Never> = .init()

  public init(displayPolicy: RealtimeConnectionDisplayPolicy = .default) {
    self.displayPolicy = displayPolicy
  }

  public convenience init(
    displayDelaySeconds: TimeInterval,
    hideDelaySeconds: TimeInterval = 1
  ) {
    self.init(displayPolicy: RealtimeConnectionDisplayPolicy(
      coldStartDelaySeconds: displayDelaySeconds,
      reconnectDelaySeconds: displayDelaySeconds,
      hideDelaySeconds: hideDelaySeconds
    ))
  }

  public func start(realtime: RealtimeV2) {
    self.realtime = realtime
    task?.cancel()
    showTask?.cancel()
    showTask = nil
    hideTask?.cancel()
    hideTask = nil

    // Subscribe to the realtime connection state
    task = Task { [weak self, realtime] in
      for await state in await realtime.connectionStates() {
        guard let self else { return }
        await MainActor.run {
          self.applyConnectionState(state)
        }
      }
    }
  }

  @MainActor
  func applyConnectionState(_ state: RealtimeConnectionState) {
    let displayPhase = currentDisplayPhase
    connectionState = state
    connectionStatePublisher.send(state)
    updateDisplayedConnectionState(for: state, displayPhase: displayPhase)
    if state == .connected || state == .updating {
      didReachConnectedState = true
    }
  }

  @MainActor
  private func updateDisplayedConnectionState(
    for state: RealtimeConnectionState,
    displayPhase: RealtimeConnectionDisplayPhase
  ) {
    switch state {
      case .connected:
        showTask?.cancel()
        showTask = nil

        guard displayedConnectionState != nil else { return }
        let hideDelaySeconds = displayPolicy.hideDelaySeconds
        hideTask?.cancel()
        hideTask = Task { [weak self] in
          do {
            try await Task.sleep(for: .seconds(hideDelaySeconds))
          } catch {
            return
          }
          await MainActor.run {
            guard let self else { return }
            guard self.connectionState == .connected else { return }
            self.setDisplayedConnectionState(nil)
            self.hideTask = nil
          }
        }
      case .connecting, .updating:
        hideTask?.cancel()
        hideTask = nil

        if displayedConnectionState != nil {
          setDisplayedConnectionState(state)
          return
        }

        guard showTask == nil else { return }
        let displayDelaySeconds = displayPolicy.showDelaySeconds(for: displayPhase)
        showTask = Task { [weak self] in
          do {
            try await Task.sleep(for: .seconds(displayDelaySeconds))
          } catch {
            return
          }
          await MainActor.run {
            guard let self else { return }
            guard self.connectionState != .connected else { return }
            self.setDisplayedConnectionState(self.connectionState)
            self.showTask = nil
          }
        }
    }
  }

  private var currentDisplayPhase: RealtimeConnectionDisplayPhase {
    didReachConnectedState ? .reconnect : .coldStart
  }

  @MainActor
  private func setDisplayedConnectionState(_ state: RealtimeConnectionState?) {
    guard displayedConnectionState != state else { return }
    displayedConnectionState = state
    displayedConnectionStatePublisher.send(state)
  }

  deinit {
    task?.cancel()
    task = nil
    showTask?.cancel()
    showTask = nil
    hideTask?.cancel()
    hideTask = nil
  }
}

import Combine
import Foundation

/// An ObservableObject class that represents the state of the Realtime connection for usage in SwiftUI views
public class RealtimeState: ObservableObject, @unchecked Sendable {
  // Private properties
  private weak var realtime: RealtimeV2?
  private var task: Task<Void, Never>?
  private var showTask: Task<Void, Never>?
  private var hideTask: Task<Void, Never>?
  private let displayDelaySeconds: TimeInterval
  private let hideDelaySeconds: TimeInterval

  // Published properties
  @Published public var connectionState: RealtimeConnectionState = .connecting
  @Published public private(set) var displayedConnectionState: RealtimeConnectionState?

  // Publishers
  public var connectionStatePublisher: PassthroughSubject<RealtimeConnectionState, Never> = .init()
  public var displayedConnectionStatePublisher: PassthroughSubject<RealtimeConnectionState?, Never> = .init()

  public init(
    displayDelaySeconds: TimeInterval = 2,
    hideDelaySeconds: TimeInterval = 1
  ) {
    self.displayDelaySeconds = displayDelaySeconds
    self.hideDelaySeconds = hideDelaySeconds
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
    connectionState = state
    connectionStatePublisher.send(state)
    updateDisplayedConnectionState(for: state)
  }

  @MainActor
  private func updateDisplayedConnectionState(for state: RealtimeConnectionState) {
    switch state {
      case .connected:
        showTask?.cancel()
        showTask = nil

        guard displayedConnectionState != nil else { return }
        let hideDelaySeconds = hideDelaySeconds
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
        let displayDelaySeconds = displayDelaySeconds
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

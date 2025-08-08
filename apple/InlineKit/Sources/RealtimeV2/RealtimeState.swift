import AsyncAlgorithms
import Combine
import Foundation
import InlineProtocol
import Logger

/// An ObservableObject class that represents the state of the Realtime connection for usage in SwiftUI views
public class RealtimeState: ObservableObject, @unchecked Sendable {
  public static let shared = RealtimeState()

  // Private properties
  private let realtime: RealtimeV2
  private var task: Task<Void, Never>?

  // Published properties
  @Published public var connectionState: RealtimeConnectionState = .connecting

  // Publishers
  public var connectionStatePublisher: PassthroughSubject<RealtimeConnectionState, Never> = .init()

  public init(realtime: RealtimeV2 = RealtimeV2.shared) {
    self.realtime = realtime

    // Subscribe to the realtime connection state
    task = Task { [realtime] in
      for await state in await realtime.connectionStates() {
        await MainActor.run {
          self.connectionState = state
          self.connectionStatePublisher.send(state)
        }
      }
    }
  }
}

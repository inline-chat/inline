import Foundation

/// An enum that represents the state of the Realtime connection
public enum RealtimeConnectionState: Sendable {
  /// The connection is being established
  case connecting

  /// Syncing updates
  case updating

  /// The connection is established and we are receiving updates
  case connected
}

public extension RealtimeConnectionState {
  var title: String {
    switch self {
      case .connecting:
        "Connecting..."
      case .updating:
        "Updating..."
      case .connected:
        "Connected"
    }
  }
}

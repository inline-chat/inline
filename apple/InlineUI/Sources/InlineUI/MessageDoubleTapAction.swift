import Foundation

public enum MessageDoubleTapAction: String, CaseIterable, Identifiable, Sendable {
  case none
  case toggleAck

  public static let storageKey = "messageDoubleTapAction"
  public static let defaultValue: Self = .toggleAck

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .none:
      "Nothing"
    case .toggleAck:
      "Toggle Ack"
    }
  }

  public static func stored(in defaults: UserDefaults = .standard) -> Self {
    guard
      let rawValue = defaults.string(forKey: storageKey),
      let action = Self(rawValue: rawValue)
    else {
      return defaultValue
    }
    return action
  }
}

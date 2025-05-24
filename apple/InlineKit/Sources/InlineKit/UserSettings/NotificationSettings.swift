import Combine
import Foundation
import InlineProtocol

public class NotificationSettingsManager: ObservableObject, Codable {
  @Published public var mode: NotificationMode
  @Published public var silent: Bool

  init() {
    // Initialize with default values
    mode = .all
    silent = false
  }

  // MARK: - Protocol

  init(from: InlineProtocol.NotificationSettings) {
    mode = switch from.mode {
      case .all: .all
      case .mentions: .mentions
      case .none: .none
      case .importantOnly: .importantOnly
      default: .all
    }

    silent = from.silent
  }

  func update(from: InlineProtocol.NotificationSettings) {
    mode = switch from.mode {
      case .all: .all
      case .mentions: .mentions
      case .none: .none
      case .importantOnly: .importantOnly
      case .unspecified: .all
      case .UNRECOGNIZED: .all
    }

    silent = from.silent
  }

  func toProtocol() -> InlineProtocol.NotificationSettings {
    InlineProtocol.NotificationSettings.with {
      $0.mode = switch mode {
        case .all: .all
        case .mentions: .mentions
        case .importantOnly: .importantOnly
        case .none: .none
      }
      $0.silent = silent
    }
  }

  // MARK: - Codable Implementation

  private enum CodingKeys: String, CodingKey {
    case mode, silent
  }

  public required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    mode = try container.decode(NotificationMode.self, forKey: .mode)
    silent = try container.decode(Bool.self, forKey: .silent)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(mode, forKey: .mode)
    try container.encode(silent, forKey: .silent)
  }
}

// MARK: - Types

public enum NotificationMode: String, Codable, Sendable {
  case all
  case none
  case mentions
  case importantOnly
}

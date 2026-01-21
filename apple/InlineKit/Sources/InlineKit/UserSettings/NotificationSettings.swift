import Combine
import Foundation
import InlineProtocol

// FIXME: need @unchecked Sendable for usage in transaction
public class NotificationSettingsManager: ObservableObject, Codable, @unchecked Sendable {
  @Published public var mode: NotificationMode
  @Published public var silent: Bool
  @Published public var disableDmNotifications: Bool
  @Published public var requiresMention: Bool
  @Published public var usesDefaultRules: Bool
  @Published public var customRules: String

  init() {
    // Initialize with default values
    mode = .all
    silent = false
    disableDmNotifications = false
    requiresMention = true
    usesDefaultRules = true
    customRules = ""
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

    if from.hasDisableDmNotifications {
      disableDmNotifications = from.disableDmNotifications
    } else {
      disableDmNotifications = false
    }

    if from.hasZenModeRequiresMention {
      requiresMention = from.zenModeRequiresMention
    } else {
      requiresMention = true
    }
    if from.hasZenModeUsesDefaultRules {
      usesDefaultRules = from.zenModeUsesDefaultRules
    } else {
      usesDefaultRules = true
    }
    if from.hasZenModeCustomRules {
      customRules = from.zenModeCustomRules
    } else {
      customRules = ""
    }
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
    if from.hasDisableDmNotifications {
      disableDmNotifications = from.disableDmNotifications
    }
    if from.hasZenModeRequiresMention {
      requiresMention = from.zenModeRequiresMention
    }
    if from.hasZenModeUsesDefaultRules {
      usesDefaultRules = from.zenModeUsesDefaultRules
    }
    if from.hasZenModeCustomRules {
      customRules = from.zenModeCustomRules
    }
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
      $0.disableDmNotifications = disableDmNotifications
      $0.zenModeRequiresMention = requiresMention
      $0.zenModeUsesDefaultRules = usesDefaultRules
      $0.zenModeCustomRules = customRules
    }
  }

  // MARK: - Codable Implementation

  private enum CodingKeys: String, CodingKey {
    case mode, silent, disableDmNotifications, requiresMention, usesDefaultRules, customRules
  }

  public required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    mode = try container.decode(NotificationMode.self, forKey: .mode)
    silent = try container.decode(Bool.self, forKey: .silent)
    disableDmNotifications = try container.decode(Bool.self, forKey: .disableDmNotifications)
    requiresMention = try container.decode(Bool.self, forKey: .requiresMention)
    usesDefaultRules = try container.decode(Bool.self, forKey: .usesDefaultRules)
    customRules = try container.decode(String.self, forKey: .customRules)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(mode, forKey: .mode)
    try container.encode(silent, forKey: .silent)
    try container.encode(disableDmNotifications, forKey: .disableDmNotifications)
    try container.encode(requiresMention, forKey: .requiresMention)
    try container.encode(usesDefaultRules, forKey: .usesDefaultRules)
    try container.encode(customRules, forKey: .customRules)
  }
}

// MARK: - Types

public enum NotificationMode: String, Codable, Sendable {
  case all
  case none
  case mentions
  case importantOnly
}

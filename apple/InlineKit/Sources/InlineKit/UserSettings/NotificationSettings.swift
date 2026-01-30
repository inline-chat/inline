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
    let hasOnlyMentions = from.mode == .onlyMentions || (from.mode == .mentions && from.disableDmNotifications)
    if hasOnlyMentions {
      mode = .onlyMentions
    } else {
      switch from.mode {
      case .all:
        mode = .all
      case .mentions:
        mode = .mentions
      case .none:
        mode = .none
      case .importantOnly:
        mode = .importantOnly
      case .onlyMentions:
        mode = .onlyMentions
      default:
        mode = .all
      }
    }

    silent = from.silent

    disableDmNotifications = hasOnlyMentions

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
    let hasOnlyMentions = from.mode == .onlyMentions || (from.mode == .mentions && from.disableDmNotifications)
    if hasOnlyMentions {
      mode = .onlyMentions
    } else {
      switch from.mode {
      case .all:
        mode = .all
      case .mentions:
        mode = .mentions
      case .none:
        mode = .none
      case .importantOnly:
        mode = .importantOnly
      case .onlyMentions:
        mode = .onlyMentions
      case .unspecified, .UNRECOGNIZED:
        mode = .all
      }
    }

    silent = from.silent
    disableDmNotifications = hasOnlyMentions
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
        case .onlyMentions: .onlyMentions
      }
      $0.silent = silent
      $0.disableDmNotifications = mode == .onlyMentions
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

    let decodedMode = try container.decode(NotificationMode.self, forKey: .mode)
    let decodedDisable = try container.decode(Bool.self, forKey: .disableDmNotifications)
    let hasOnlyMentions = decodedMode == .onlyMentions || (decodedMode == .mentions && decodedDisable)
    mode = hasOnlyMentions ? .onlyMentions : decodedMode
    silent = try container.decode(Bool.self, forKey: .silent)
    disableDmNotifications = hasOnlyMentions
    requiresMention = try container.decode(Bool.self, forKey: .requiresMention)
    usesDefaultRules = try container.decode(Bool.self, forKey: .usesDefaultRules)
    customRules = try container.decode(String.self, forKey: .customRules)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(mode, forKey: .mode)
    try container.encode(silent, forKey: .silent)
    try container.encode(mode == .onlyMentions, forKey: .disableDmNotifications)
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
  case onlyMentions
}

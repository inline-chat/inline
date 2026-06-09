import Combine
import Foundation
import InlineProtocol

// FIXME: need @unchecked Sendable for usage in transaction
public class NotificationSettingsManager: ObservableObject, Codable, @unchecked Sendable {
  @Published public var mode: NotificationMode
  @Published public var silent: Bool
  @Published public var disableDmNotifications: Bool

  init() {
    // Initialize with default values
    mode = .all
    silent = false
    disableDmNotifications = false
  }

  // MARK: - Protocol

  init(from: InlineProtocol.NotificationSettings) {
    let mode = NotificationSettingsCompat.mode(from: from.mode, disableDmNotifications: from.disableDmNotifications)
    self.mode = mode
    silent = from.silent
    disableDmNotifications = mode == .onlyMentions
  }

  func update(from: InlineProtocol.NotificationSettings) {
    mode = NotificationSettingsCompat.mode(from: from.mode, disableDmNotifications: from.disableDmNotifications)
    silent = from.silent
    disableDmNotifications = mode == .onlyMentions
  }

  func toProtocol() -> InlineProtocol.NotificationSettings {
    InlineProtocol.NotificationSettings.with {
      $0.mode = NotificationSettingsCompat.protocolMode(from: mode)
      $0.silent = silent
      $0.disableDmNotifications = mode == .onlyMentions
    }
  }

  // MARK: - Codable Implementation

  private enum CodingKeys: String, CodingKey {
    case mode, silent, disableDmNotifications
  }

  public required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    let decodedMode = try container.decode(NotificationMode.self, forKey: .mode)
    let decodedDisable = try container.decode(Bool.self, forKey: .disableDmNotifications)
    let mode = NotificationSettingsCompat.mode(from: decodedMode, disableDmNotifications: decodedDisable)
    self.mode = mode
    silent = try container.decode(Bool.self, forKey: .silent)
    disableDmNotifications = mode == .onlyMentions
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(mode, forKey: .mode)
    try container.encode(silent, forKey: .silent)
    try container.encode(mode == .onlyMentions, forKey: .disableDmNotifications)
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

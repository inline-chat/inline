import Combine
import Foundation
import InlineProtocol

public final class PrivacySettingsManager: ObservableObject, Codable, @unchecked Sendable {
  @Published public var shareTimeZone: Bool
  @Published public var appearInGlobalSearch: Bool

  public init(
    shareTimeZone: Bool = true,
    appearInGlobalSearch: Bool = true
  ) {
    self.shareTimeZone = shareTimeZone
    self.appearInGlobalSearch = appearInGlobalSearch
  }

  convenience init(from settings: InlineProtocol.PrivacySettings) {
    self.init(
      shareTimeZone: settings.hasShareTimeZone ? settings.shareTimeZone : true,
      appearInGlobalSearch: settings.hasAppearInGlobalSearch ? settings.appearInGlobalSearch : true
    )
  }

  func toProtocol() -> InlineProtocol.PrivacySettings {
    .with {
      $0.shareTimeZone = shareTimeZone
      $0.appearInGlobalSearch = appearInGlobalSearch
    }
  }

  private enum CodingKeys: String, CodingKey {
    case shareTimeZone
    case appearInGlobalSearch
  }

  public required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    shareTimeZone = try container.decodeIfPresent(Bool.self, forKey: .shareTimeZone) ?? true
    appearInGlobalSearch = try container.decodeIfPresent(Bool.self, forKey: .appearInGlobalSearch) ?? true
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(shareTimeZone, forKey: .shareTimeZone)
    try container.encode(appearInGlobalSearch, forKey: .appearInGlobalSearch)
  }
}

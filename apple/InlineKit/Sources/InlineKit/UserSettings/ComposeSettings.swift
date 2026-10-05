import Combine
import Foundation
import InlineProtocol

public final class ComposeSettingsManager: ObservableObject, Codable, @unchecked Sendable {
  @Published public var replacePastedLinksWithTitles: Bool
  @Published public var sendWithReturnOnIPad: Bool {
    didSet { localDefaults.set(sendWithReturnOnIPad, forKey: Self.sendWithReturnOnIPadKey) }
  }

  static let sendWithReturnOnIPadKey = "compose.sendWithReturnOnIPad"
  private let localDefaults: UserDefaults

  public init(replacePastedLinksWithTitles: Bool = false, localDefaults: UserDefaults = .shared) {
    self.replacePastedLinksWithTitles = replacePastedLinksWithTitles
    self.localDefaults = localDefaults
    sendWithReturnOnIPad = (localDefaults.object(forKey: Self.sendWithReturnOnIPadKey) as? Bool) ?? true
  }

  convenience init(from settings: InlineProtocol.ComposeSettings) {
    self.init(
      replacePastedLinksWithTitles: settings.hasReplacePastedLinksWithTitles
        ? settings.replacePastedLinksWithTitles
        : false
    )
  }

  func toProtocol() -> InlineProtocol.ComposeSettings {
    .with {
      $0.replacePastedLinksWithTitles = replacePastedLinksWithTitles
    }
  }

  private enum CodingKeys: String, CodingKey {
    case replacePastedLinksWithTitles
  }

  public required init(from decoder: Decoder) throws {
    localDefaults = .shared
    sendWithReturnOnIPad = (localDefaults.object(forKey: Self.sendWithReturnOnIPadKey) as? Bool) ?? true
    let container = try decoder.container(keyedBy: CodingKeys.self)
    replacePastedLinksWithTitles = try container.decodeIfPresent(
      Bool.self,
      forKey: .replacePastedLinksWithTitles
    ) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(replacePastedLinksWithTitles, forKey: .replacePastedLinksWithTitles)
  }
}

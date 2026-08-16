import Combine
import Foundation
import InlineProtocol

public final class ComposeSettingsManager: ObservableObject, Codable, @unchecked Sendable {
  @Published public var replacePastedLinksWithTitles: Bool

  public init(replacePastedLinksWithTitles: Bool = false) {
    self.replacePastedLinksWithTitles = replacePastedLinksWithTitles
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

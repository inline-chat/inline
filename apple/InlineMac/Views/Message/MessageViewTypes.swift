import Foundation

enum MessageRenderStyle: String, Codable, CaseIterable, Hashable {
  case bubble
  case minimal

  var title: String {
    switch self {
    case .bubble:
      return "Bubble"
    case .minimal:
      return "Minimal"
    }
  }
}

struct MessageViewInputProps: Equatable, Codable, Hashable {
  var firstInGroup: Bool
  var isLastMessage: Bool
  var isFirstMessage: Bool
  var isDM: Bool
  var isRtl: Bool
  var translated: Bool
  var renderStyle: MessageRenderStyle

  /// Used in cache key
  func toString() -> String {
    "\(firstInGroup ? "FG" : "")\(isLastMessage == true ? "LM" : "")\(isFirstMessage == true ? "FM" : "")\(isRtl ? "RTL" : "")\(isDM ? "DM" : "")\(translated ? "TR" : "")\(renderStyle == .minimal ? "MN" : "BB")"
  }
}

struct MessageViewProps: Equatable, Codable, Hashable {
  var firstInGroup: Bool
  var isLastMessage: Bool
  var isFirstMessage: Bool
  var isRtl: Bool
  var isDM: Bool = false
  var renderStyle: MessageRenderStyle = .bubble
  var index: Int?
  var translated: Bool
  var layout: MessageSizeCalculator.LayoutPlans

  func equalExceptSize(_ rhs: MessageViewProps) -> Bool {
    firstInGroup == rhs.firstInGroup &&
      isLastMessage == rhs.isLastMessage &&
      isFirstMessage == rhs.isFirstMessage &&
      isRtl == rhs.isRtl &&
      isDM == rhs.isDM &&
      renderStyle == rhs.renderStyle &&
      translated == rhs.translated
  }
}

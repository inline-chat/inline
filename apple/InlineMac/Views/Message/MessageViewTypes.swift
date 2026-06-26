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

enum MessageInteractionMode: String, Codable, Hashable {
  case normal
  case threadAnchor
}

struct MessageViewInputProps: Equatable, Codable, Hashable {
  var firstInGroup: Bool
  var lastInGroup: Bool
  var startsAfterDaySeparator: Bool = false
  var isLastMessage: Bool
  var isFirstMessage: Bool
  var isDM: Bool
  var isRtl: Bool
  var translated: Bool
  var renderStyle: MessageRenderStyle
  var interactionMode: MessageInteractionMode = .normal
  var replyThreadTitle: String? = nil

  /// Used in cache key
  func toString() -> String {
    "\(firstInGroup ? "FG" : "")\(lastInGroup ? "LG" : "")\(renderStyle == .minimal && startsAfterDaySeparator ? "DS" : "")\(isLastMessage == true ? "LM" : "")\(isFirstMessage == true ? "FM" : "")\(isRtl ? "RTL" : "")\(isDM ? "DM" : "")\(translated ? "TR" : "")\(renderStyle == .minimal ? "MN" : "BB")\(interactionMode == .threadAnchor ? "TA" : "NM")\(replyThreadTitle?.isEmpty == false ? "RT" : "")"
  }
}

struct MessageViewProps: Equatable, Codable, Hashable {
  var firstInGroup: Bool
  var lastInGroup: Bool
  var startsAfterDaySeparator: Bool = false
  var isLastMessage: Bool
  var isFirstMessage: Bool
  var isRtl: Bool
  var isDM: Bool = false
  var renderStyle: MessageRenderStyle = .bubble
  var index: Int?
  var translated: Bool
  var interactionMode: MessageInteractionMode = .normal
  var replyThreadTitle: String? = nil
  var usesAvatarOverlay: Bool = true
  var layout: MessageSizeCalculator.LayoutPlans

  func equalExceptSize(_ rhs: MessageViewProps) -> Bool {
    firstInGroup == rhs.firstInGroup &&
      lastInGroup == rhs.lastInGroup &&
      (renderStyle == .bubble || startsAfterDaySeparator == rhs.startsAfterDaySeparator) &&
      isLastMessage == rhs.isLastMessage &&
      isFirstMessage == rhs.isFirstMessage &&
      isRtl == rhs.isRtl &&
      isDM == rhs.isDM &&
      renderStyle == rhs.renderStyle &&
      interactionMode == rhs.interactionMode &&
      replyThreadTitle == rhs.replyThreadTitle &&
      usesAvatarOverlay == rhs.usesAvatarOverlay &&
      translated == rhs.translated
  }
}

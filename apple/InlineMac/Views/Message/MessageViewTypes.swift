import InlineKit
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
  /// Photos, videos and files sent with the row's message: the photos and videos drawn as one
  /// grid in its photo's place, the files as rows in its document's place.
  var album: MessageAlbum? = nil

  /// Used in cache key
  func toString() -> String {
    "\(albumSignature)\(firstInGroup ? "FG" : "")\(lastInGroup ? "LG" : "")\(renderStyle == .minimal && startsAfterDaySeparator ? "DS" : "")\(isLastMessage == true ? "LM" : "")\(isFirstMessage == true ? "FM" : "")\(isRtl ? "RTL" : "")\(isDM ? "DM" : "")\(translated ? "TR" : "")\(renderStyle == .minimal ? "MN" : "BB")\(interactionMode == .threadAnchor ? "TA" : "NM")\(replyThreadTitle?.isEmpty == false ? "RT" : "")"
  }
}

extension MessageViewInputProps {
  /// The album's items and their shapes, so a grid or file list that gains or loses an item (or a
  /// file that gains a thumbnail, which makes its row taller) is measured again.
  var albumSignature: String {
    guard let album else { return "" }
    return "AL\(album.items.map(Self.albumItemSignature).joined(separator: ","))"
  }

  private static func albumItemSignature(_ item: FullMessage) -> String {
    if let document = item.documentInfo {
      return "\(item.id):F\(document.id)\(document.thumbnail != nil ? "T" : "")"
    }
    return "\(item.id):\(item.photoInfo?.id ?? item.videoInfo?.id ?? 0)"
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
  var richBlockCodePresentation: RichBlockCodePresentation = .syntaxHighlighted
  /// Photos and videos sent with the row's message, drawn as one grid in its photo's place.
  var album: MessageAlbum? = nil
  var layout: MessageSizeCalculator.LayoutPlans
  /// A typography change must rebuild the text, not just resize the existing view.
  var typographyRevision: Int = ChatTypography.current.revision

  func equalExceptSize(_ rhs: MessageViewProps) -> Bool {
    typographyRevision == rhs.typographyRevision &&
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
      richBlockCodePresentation == rhs.richBlockCodePresentation &&
      translated == rhs.translated &&
      album == rhs.album
  }

  /// `equalExceptSize` without where the row sits in its sender group or in the chat. A minimal row
  /// reads those when it updates (a group's top spacing, the via footer, upload progress), and the
  /// layout plan's constraint shape already covers the name and avatar that `firstInGroup` decides.
  func equalExceptSizeAndGroupPosition(_ rhs: MessageViewProps) -> Bool {
    var lhs = self
    lhs.lastInGroup = rhs.lastInGroup
    lhs.startsAfterDaySeparator = rhs.startsAfterDaySeparator
    lhs.isLastMessage = rhs.isLastMessage
    lhs.isFirstMessage = rhs.isFirstMessage
    return lhs.equalExceptSize(rhs)
  }

  /// `equalExceptSizeAndGroupPosition`, also ignoring whether the row starts its group. A bubble row places its parts
  /// from the plan on every layout pass, and the plan's shape covers the name and avatar `firstInGroup` decides.
  func equalExceptSizeAndAnyGroupPosition(_ rhs: MessageViewProps) -> Bool {
    var lhs = self
    lhs.firstInGroup = rhs.firstInGroup
    return lhs.equalExceptSizeAndGroupPosition(rhs)
  }
}

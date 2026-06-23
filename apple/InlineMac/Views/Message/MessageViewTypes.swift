import CoreGraphics
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
    "\(firstInGroup ? "FG" : "")\(renderStyle == .minimal && startsAfterDaySeparator ? "DS" : "")\(isLastMessage == true ? "LM" : "")\(isFirstMessage == true ? "FM" : "")\(isRtl ? "RTL" : "")\(isDM ? "DM" : "")\(translated ? "TR" : "")\(renderStyle == .minimal ? "MN" : "BB")\(interactionMode == .threadAnchor ? "TA" : "NM")\(replyThreadTitle?.isEmpty == false ? "RT" : "")"
  }
}

struct MessageViewProps: Equatable, Codable, Hashable {
  var firstInGroup: Bool
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
  var layout: MessageSizeCalculator.LayoutPlans

  func equalExceptSize(_ rhs: MessageViewProps) -> Bool {
    firstInGroup == rhs.firstInGroup &&
      (renderStyle == .bubble || startsAfterDaySeparator == rhs.startsAfterDaySeparator) &&
      isLastMessage == rhs.isLastMessage &&
      isFirstMessage == rhs.isFirstMessage &&
      isRtl == rhs.isRtl &&
      isDM == rhs.isDM &&
      renderStyle == rhs.renderStyle &&
      interactionMode == rhs.interactionMode &&
      replyThreadTitle == rhs.replyThreadTitle &&
      translated == rhs.translated
  }
}

#if DEBUG
struct RichTextSlotDebugSnapshot {
  let usesRichBlockRenderer: Bool
  let textViewAttached: Bool
  let richViewAttached: Bool
  let widthConstraintActive: Bool
  let heightConstraintActive: Bool
  let topConstraintActive: Bool
  let leadingConstraintActive: Bool
  let widthConstraintConstant: CGFloat?
  let heightConstraintConstant: CGFloat?

  var hasActiveTextSlotConstraints: Bool {
    widthConstraintActive && heightConstraintActive && topConstraintActive && leadingConstraintActive
  }
}

struct RichTextInteractionDebugSnapshot {
  let copiedText: String
  let copiedHasRTF: Bool
  let dragDidStart: Bool
  let dragSelectedText: String
  let dragSelectionDiagnostics: RichRendererSelectionDiagnostics
  let spoilerDiagnostics: RichRendererSpoilerDiagnostics
  let contextMenuTitles: [String]
  let contextCopyActions: [RichContextCopyActionDebugSnapshot]
  let copyableBlocks: [RichCopyableBlockDebugSnapshot]
  let mediaClicks: RichMediaClickDebugSnapshot
}

struct RichMediaScrollDebugSnapshot {
  var mediaViewCount = 0
  var scrollingMediaViewCount = 0
  var idleMediaViewCount = 0
  var nativeMediaViewCount = 0
  var scrollingNativeMediaViewCount = 0
  var idleNativeMediaViewCount = 0
  var mediaViewFrames: [CGRect] = []

  mutating func merge(_ other: RichMediaScrollDebugSnapshot) {
    mediaViewCount += other.mediaViewCount
    scrollingMediaViewCount += other.scrollingMediaViewCount
    idleMediaViewCount += other.idleMediaViewCount
    nativeMediaViewCount += other.nativeMediaViewCount
    scrollingNativeMediaViewCount += other.scrollingNativeMediaViewCount
    idleNativeMediaViewCount += other.idleNativeMediaViewCount
    mediaViewFrames.append(contentsOf: other.mediaViewFrames)
  }
}

struct RichMediaClickDebugSnapshot {
  var mediaViewCount = 0
  var imageMediaViewCount = 0
  var previewableImageCount = 0
  var primaryPreviewOnlyCount = 0
  var primarySourceOpenCount = 0
  var quickLookPreparedImageCount = 0
  var quickLookPrepareFailureCount = 0
  var quickLookPrepareFailureDetails: [String] = []
  var primaryClickDispatchPreviewCount = 0
  var primaryClickDispatchSourceOpenCount = 0
  var primaryClickClosesPreviewPanelCount = 0
  var imagePrimaryHitTargetCount = 0
  var imagePrimaryHitTargetMissCount = 0
  var imagePrimaryHitTargetMissDetails: [String] = []
  var nonImagePrimaryPreviewCount = 0
  var imageSourceContextMenuActionCount = 0
  var imageSourceCopyActionCount = 0
  var nonImageSourceContextMenuActionCount = 0
  var nonImageSourceCopyActionCount = 0
  var sourceContextMenuActionCount = 0

  mutating func merge(_ other: RichMediaClickDebugSnapshot) {
    mediaViewCount += other.mediaViewCount
    imageMediaViewCount += other.imageMediaViewCount
    previewableImageCount += other.previewableImageCount
    primaryPreviewOnlyCount += other.primaryPreviewOnlyCount
    primarySourceOpenCount += other.primarySourceOpenCount
    quickLookPreparedImageCount += other.quickLookPreparedImageCount
    quickLookPrepareFailureCount += other.quickLookPrepareFailureCount
    quickLookPrepareFailureDetails.append(contentsOf: other.quickLookPrepareFailureDetails)
    primaryClickDispatchPreviewCount += other.primaryClickDispatchPreviewCount
    primaryClickDispatchSourceOpenCount += other.primaryClickDispatchSourceOpenCount
    primaryClickClosesPreviewPanelCount += other.primaryClickClosesPreviewPanelCount
    imagePrimaryHitTargetCount += other.imagePrimaryHitTargetCount
    imagePrimaryHitTargetMissCount += other.imagePrimaryHitTargetMissCount
    imagePrimaryHitTargetMissDetails.append(contentsOf: other.imagePrimaryHitTargetMissDetails)
    nonImagePrimaryPreviewCount += other.nonImagePrimaryPreviewCount
    imageSourceContextMenuActionCount += other.imageSourceContextMenuActionCount
    imageSourceCopyActionCount += other.imageSourceCopyActionCount
    nonImageSourceContextMenuActionCount += other.nonImageSourceContextMenuActionCount
    nonImageSourceCopyActionCount += other.nonImageSourceCopyActionCount
    sourceContextMenuActionCount += other.sourceContextMenuActionCount
  }
}

struct RichCopyableBlockDebugSnapshot {
  let menuTitle: String
  let expectedText: String
  let copiedText: String
  let actionButtonExists: Bool
  let actionButtonHitTested: Bool
  let actionButtonCopiedText: String
  let actionButtonFrame: CGRect?

  var didCopyExpectedText: Bool {
    !expectedText.isEmpty && copiedText == expectedText
  }

  var didActionButtonCopyExpectedText: Bool {
    !expectedText.isEmpty && actionButtonCopiedText == expectedText
  }
}

struct RichContextCopyActionDebugSnapshot {
  let menuTitle: String
  let expectedText: String
  let copiedText: String
  let source: String
  let sourceHitTested: Bool
  let sourceHitView: String

  init(
    menuTitle: String,
    expectedText: String,
    copiedText: String,
    source: String = "",
    sourceHitTested: Bool = false,
    sourceHitView: String = ""
  ) {
    self.menuTitle = menuTitle
    self.expectedText = expectedText
    self.copiedText = copiedText
    self.source = source
    self.sourceHitTested = sourceHitTested
    self.sourceHitView = sourceHitView
  }

  var didCopyExpectedText: Bool {
    !expectedText.isEmpty && copiedText == expectedText
  }
}

struct RichMessageActionRowsDebugSnapshot {
  let attached: Bool
  let rowCount: Int
  let actionCount: Int
  let hitTestableActionCount: Int
  let hoverResponsiveActionCount: Int
  let pressResponsiveActionCount: Int
  let restoredInteractionActionCount: Int
  let widthConstraintActive: Bool
  let heightConstraintActive: Bool
  let topConstraintActive: Bool
  let sideConstraintActive: Bool
  let widthConstraintConstant: CGFloat?
  let heightConstraintConstant: CGFloat?
  let topConstraintConstant: CGFloat?
  let frameWidth: CGFloat
  let frameHeight: CGFloat

  var hasActiveConstraints: Bool {
    widthConstraintActive && heightConstraintActive && topConstraintActive && sideConstraintActive
  }
}

struct RichMessageTimeStatusDebugSnapshot {
  let attached: Bool
  let hidden: Bool
  let frameInRow: CGRect
  let frameInBubble: CGRect
  let frameInContent: CGRect
  let widthConstraintActive: Bool
  let heightConstraintActive: Bool
  let topConstraintActive: Bool
  let bottomConstraintActive: Bool
  let leadingConstraintActive: Bool
  let trailingConstraintActive: Bool
  let centerYConstraintActive: Bool
  let widthConstraintConstant: CGFloat?
  let heightConstraintConstant: CGFloat?
  let topConstraintConstant: CGFloat?
  let bottomConstraintConstant: CGFloat?
  let leadingConstraintConstant: CGFloat?
  let trailingConstraintConstant: CGFloat?
  let centerYConstraintConstant: CGFloat?
}
#endif

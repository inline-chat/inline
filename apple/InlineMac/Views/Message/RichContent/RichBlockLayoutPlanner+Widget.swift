import AppKit
import InlineKit
import InlineProtocol

/// Shared by the planner and the widget node view, so planned and rendered geometry never drift.
enum RichBlockWidgetMetrics {
  /// The title and Open row above the frame (`WidgetHostView.headerHeight`).
  static let headerHeight: CGFloat = 24
  static let inlineHeightCap: CGFloat = 720
  static let defaultContentHeight: CGFloat = 240
  static let minimumContentHeight: CGFloat = 80
  static let maximumContentHeight: CGFloat = 2_000

  /// Measured height, then the sender's hint, then the default; clamped, then capped inline.
  static func contentHeight(measured: Int?, hint: Int?) -> (height: CGFloat, isClipped: Bool) {
    let raw = CGFloat(measured ?? hint ?? Int(defaultContentHeight))
    let clamped = min(maximumContentHeight, max(minimumContentHeight, raw))
    return (min(clamped, inlineHeightCap), clamped > inlineHeightCap)
  }
}

/// Planner input while widgets are enabled. Measured heights come from the live
/// web views, by widget ID, for this message's current revision.
struct RichBlockWidgetLayout: Hashable {
  var measuredHeights: [String: Int]

  var cacheKey: String {
    measuredHeights.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
  }
}

struct RichBlockWidgetNode: Codable, Hashable {
  var widgetID: String
  var title: RichBlockTextRange
  /// What the row shows: the measured height capped inline. The page itself may be taller.
  var contentHeight: CGFloat
  var isClipped: Bool
}

extension RichBlockLayoutPlanner.Builder {
  mutating func appendWidget(
    _ widget: InlineProtocol.BlockWidget,
    layout: RichBlockWidgetLayout,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat
  ) -> Bool {
    let widgetID = widget.widgetID.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = RichBlockTextRange(widget.title)
    guard !widgetID.isEmpty, !widget.html.isEmpty, widget.hasTitle,
          title.offset >= 0, title.length > 0, title.offset <= attributedText.length,
          title.length <= attributedText.length - title.offset
    else { return false }
    let content = RichBlockWidgetMetrics.contentHeight(
      measured: layout.measuredHeights[widgetID],
      hint: widget.hasHeight ? Int(widget.height) : nil
    )
    let node = RichBlockWidgetNode(
      widgetID: widgetID,
      title: title,
      contentHeight: content.height,
      isClipped: content.isClipped
    )
    let frame = CGRect(x: x, y: height, width: width, height: RichBlockWidgetMetrics.headerHeight + content.height)
    nodes.append(.init(path: path, frame: frame, kind: .widget(node)))
    claimMaximumWidth()
    height = frame.maxY
    return true
  }
}

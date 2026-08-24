import AppKit

enum RichBlockListMetrics {
  static let markerContentGap: CGFloat = 6
  static let unorderedMarkerWidth: CGFloat = 17
  static let itemSpacing: CGFloat = 4
  static let leadingInset: CGFloat = 7
  static let nestedIndent: CGFloat = 3

  static func markerWidth(
    ordered: Bool,
    lastOrdinal: Int64,
    baseFontSize: CGFloat
  ) -> CGFloat {
    guard ordered else { return unorderedMarkerWidth }
    let marker = "\(lastOrdinal)." as NSString
    let markerWidth = marker.size(
      withAttributes: [.font: ChatTypography.current.font(sized: baseFontSize)]
    ).width
    return ceil(max(unorderedMarkerWidth, markerWidth + markerContentGap))
  }

  static func markerHeight(baseFontSize: CGFloat) -> CGFloat {
    ceil(baseFontSize * 1.25)
  }

  static func unorderedDiameter(baseFontSize: CGFloat) -> CGFloat {
    max(4.25, baseFontSize * 0.27)
  }
}

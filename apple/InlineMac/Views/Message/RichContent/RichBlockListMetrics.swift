import AppKit

/// List geometry from the chat spacing scale, at the message's base font size.
enum RichBlockListMetrics {
  /// Extra indent for a list nested in a list item.
  static let nestedIndent: CGFloat = 3

  /// Width of the marker column for an unordered list; item text starts after it.
  static func markerColumn(baseFontSize: CGFloat) -> CGFloat {
    ChatTypography.space(.listMarkerColumn, at: baseFontSize)
  }

  /// Space between a marker and its item's text. Dots sit farther out than numbers
  /// and checkboxes, which are wider and would otherwise drift off their text.
  static func markerGap(for marker: String, baseFontSize: CGFloat) -> CGFloat {
    ChatTypography.space(marker == "•" ? .bulletToText : .numberToText, at: baseFontSize)
  }

  static func markerWidth(
    ordered: Bool,
    lastOrdinal: Int64,
    baseFontSize: CGFloat
  ) -> CGFloat {
    let column = markerColumn(baseFontSize: baseFontSize)
    guard ordered else { return column }
    let marker = "\(lastOrdinal)." as NSString
    let markerWidth = marker.size(
      withAttributes: [.font: ChatTypography.current.font(sized: baseFontSize)]
    ).width
    return ceil(max(column, markerWidth + markerGap(for: "1.", baseFontSize: baseFontSize)))
  }

  static func markerHeight(baseFontSize: CGFloat) -> CGFloat {
    ceil(baseFontSize * 1.25)
  }

  static func unorderedDiameter(baseFontSize: CGFloat) -> CGFloat {
    ChatTypography.bulletDiameter(at: baseFontSize)
  }
}

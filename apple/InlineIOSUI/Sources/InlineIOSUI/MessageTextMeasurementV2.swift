#if canImport(UIKit)
import UIKit

/// TextKit geometry shared by flat and structural message text.
public struct MessageTextMeasurementV2 {
  public let size: CGSize
  public let lineCount: Int
  public let lastLineWidth: CGFloat
  public let lastLineHeight: CGFloat

  @MainActor private static let measurementView: UITextView = {
    let view = UITextView(usingTextLayoutManager: false)
    view.isEditable = false
    view.isSelectable = false
    // A non-scrolling UITextView eagerly computes intrinsic height during text
    // assignment. This private stack lays out explicitly once below instead.
    view.isScrollEnabled = true
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.textContainer.widthTracksTextView = false
    view.textContainer.heightTracksTextView = false
    return view
  }()

  @MainActor public static func measure(
    _ text: NSAttributedString,
    maximumWidth: CGFloat,
    minimumLineHeight: CGFloat = 0
  ) -> Self {
    // UIKit's text storage preserves the original font's line metrics while
    // substituting Arabic, Devanagari and other fallback fonts. A standalone
    // NSTextStorage does not. Reuse one native stack instead of reproducing
    // UIKit's private font attributes or constructing a view for each block.
    let view = measurementView
    let manager = view.layoutManager
    let container = view.textContainer
    container.size = CGSize(width: max(1, maximumWidth), height: .greatestFiniteMagnitude)
    container.lineBreakMode = .byWordWrapping
    view.attributedText = text
    defer { view.attributedText = nil }
    manager.ensureLayout(for: container)

    var width: CGFloat = 0
    var lineCount = 0
    var lastLineWidth: CGFloat = 0
    var lastLineHeight = minimumLineHeight
    manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
      width = max(width, used.width)
      lastLineWidth = used.width
      lastLineHeight = used.height
      lineCount += 1
    }
    var height = manager.usedRect(for: container).maxY
    // A terminal newline owns an empty visible line in UITextView. It has no glyphs,
    // so measuring only usedRect/enumerateLineFragments clips the last line.
    if manager.extraLineFragmentTextContainer === container {
      let extraLine = manager.extraLineFragmentRect
      height = max(height, extraLine.maxY)
      lastLineWidth = 0
      lastLineHeight = extraLine.height
      lineCount += 1
    }
    return Self(
      size: CGSize(width: max(1, ceil(width)), height: max(ceil(minimumLineHeight), ceil(height))),
      lineCount: lineCount,
      lastLineWidth: ceil(lastLineWidth),
      lastLineHeight: ceil(lastLineHeight)
    )
  }
}
#endif

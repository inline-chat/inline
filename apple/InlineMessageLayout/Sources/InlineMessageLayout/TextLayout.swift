import CoreGraphics
import CoreText
import Foundation

public struct TextLayoutStyle: Hashable, Sendable {
  /// Extra space between lines of one paragraph.
  public var lineSpacing: CGFloat
  /// Extra space after a hard line break.
  public var paragraphSpacing: CGFloat
  public var minimumLineHeight: CGFloat
  /// Direction for paragraphs with no letters, usually the UI direction.
  public var fallbackDirection: TextDirection

  public init(
    lineSpacing: CGFloat = 0,
    paragraphSpacing: CGFloat = 0,
    minimumLineHeight: CGFloat = 0,
    fallbackDirection: TextDirection = .leftToRight
  ) {
    self.lineSpacing = lineSpacing
    self.paragraphSpacing = paragraphSpacing
    self.minimumLineHeight = minimumLineHeight
    self.fallbackDirection = fallbackDirection
  }
}

/// Typeset text: the one result that is measured, drawn and hit-tested.
///
/// Coordinates are y-down with the origin at the top-left of the text block. Lines start at
/// x = 0; `aligned(toWidth:)` moves right-to-left paragraphs to the trailing edge once the
/// final block width is known.
public struct TextLayout: Sendable {
  public struct Line: Sendable {
    public let range: NSRange
    /// Line box. Its width is the typographic width without trailing whitespace.
    public internal(set) var frame: CGRect
    public internal(set) var baseline: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let direction: TextDirection
    public let endsParagraph: Bool
    let storage: LineStorage

    public var ctLine: CTLine { storage.line }
    public var width: CGFloat { frame.width }
    /// Origin to pass to `CTLineDraw` in a y-down context flipped per line.
    public var drawingOrigin: CGPoint { CGPoint(x: frame.minX, y: baseline) }
  }

  public internal(set) var lines: [Line]
  public internal(set) var size: CGSize
  public let maximumWidth: CGFloat
  public let length: Int

  public var lineCount: Int { lines.count }
  public var lastLine: Line? { lines.last }
  public var firstBaseline: CGFloat { lines.first?.baseline ?? 0 }
  public var lastBaseline: CGFloat { lines.last?.baseline ?? 0 }

  public static let empty = TextLayout(lines: [], size: .zero, maximumWidth: 0, length: 0)

  /// Places each line at its paragraph's leading edge within a block of `width`.
  public func aligned(toWidth width: CGFloat) -> TextLayout {
    var copy = self
    let blockWidth = max(width, size.width)
    copy.size.width = blockWidth
    for index in copy.lines.indices {
      let line = copy.lines[index]
      let x = line.direction == .rightToLeft ? blockWidth - line.frame.width : 0
      copy.lines[index].frame.origin.x = x
    }
    return copy
  }

  /// Character whose glyph covers `point`, or nil outside the drawn text.
  public func characterIndex(at point: CGPoint) -> Int? {
    guard let line = lines.first(where: { $0.frame.minY <= point.y && point.y < $0.frame.maxY }) else {
      return nil
    }
    let x = point.x - line.frame.minX
    for run in line.storage.runs {
      for glyph in run.glyphs where glyph.minX <= x && x < glyph.maxX {
        return glyph.stringIndex
      }
    }
    return nil
  }

  /// Line-height rects covering the glyphs of `range`, one per contiguous visual segment.
  public func rects(for range: NSRange) -> [CGRect] {
    guard range.length > 0 else { return [] }
    var result: [CGRect] = []
    for line in lines where NSIntersectionRange(line.range, range).length > 0 {
      var segments: [ClosedRange<CGFloat>] = []
      for run in line.storage.runs {
        for glyph in run.glyphs where NSLocationInRange(glyph.stringIndex, range) {
          if let last = segments.last, abs(last.upperBound - glyph.minX) < 0.5 {
            segments[segments.count - 1] = last.lowerBound ... max(last.upperBound, glyph.maxX)
          } else {
            segments.append(glyph.minX ... glyph.maxX)
          }
        }
      }
      for segment in segments {
        result.append(CGRect(
          x: line.frame.minX + segment.lowerBound,
          y: line.frame.minY,
          width: segment.upperBound - segment.lowerBound,
          height: line.frame.height
        ))
      }
    }
    return result
  }

  /// Height of the lines that hold the first `characterCount` characters, for paced reveal.
  public func height(revealingCharacters characterCount: Int) -> CGFloat {
    guard characterCount < length else { return size.height }
    guard let line = lines.first(where: { NSMaxRange($0.range) > characterCount }) ?? lines.last else {
      return 0
    }
    return line.frame.maxY
  }
}

/// CTLine is an immutable CF object, safe to share across threads.
final class LineStorage: @unchecked Sendable {
  struct Glyph {
    let stringIndex: Int
    let minX: CGFloat
    let maxX: CGFloat
  }

  struct Run {
    let glyphs: [Glyph]
  }

  let line: CTLine
  let runs: [Run]

  init(line: CTLine) {
    self.line = line
    let ctRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    runs = ctRuns.map { run in
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { return Run(glyphs: []) }
      var positions = [CGPoint](repeating: .zero, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
      CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
      CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
      return Run(glyphs: (0 ..< count).map { index in
        Glyph(
          stringIndex: indices[index],
          minX: positions[index].x,
          maxX: positions[index].x + advances[index].width
        )
      })
    }
  }
}

public enum TextLayouter {
  /// Breaks `text` into lines no wider than `maximumWidth`.
  public static func layout(
    _ text: MessageText,
    style: TextLayoutStyle = .init(),
    maximumWidth: CGFloat,
    grid: PixelGrid
  ) -> TextLayout {
    let attributed = text.attributedString
    let length = attributed.length
    let width = TextLayouter.clampedWidth(maximumWidth)
    guard length > 0 else {
      return TextLayout(lines: [], size: .zero, maximumWidth: width, length: 0)
    }

    let string = attributed.string as NSString
    let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
    var lines: [TextLayout.Line] = []
    var y: CGFloat = 0
    var widest: CGFloat = 0
    var start = 0
    var paragraphStart = 0
    var paragraphDirection = direction(of: string, from: 0, style: style)

    while start < length {
      if start == paragraphStart {
        paragraphDirection = direction(of: string, from: start, style: style)
      }
      var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
      if count <= 0 {
        // Narrower than one cluster: take the cluster anyway rather than loop forever.
        count = string.rangeOfComposedCharacterSequence(at: start).length
      }
      let range = NSRange(location: start, length: count)
      let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      var leading: CGFloat = 0
      let typographicWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
      let trailingWhitespace = CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine))
      let lineWidth = max(0, typographicWidth - trailingWhitespace)
      let endsParagraph = endsWithHardBreak(string, range: range) || NSMaxRange(range) >= length

      let natural = ascent + descent + leading
      let lineHeight = grid.ceil(max(natural, style.minimumLineHeight))
      let baseline = grid.round(y + (lineHeight - natural) + ascent)
      lines.append(TextLayout.Line(
        range: range,
        frame: CGRect(x: 0, y: y, width: lineWidth, height: lineHeight),
        baseline: baseline,
        ascent: ascent,
        descent: descent,
        direction: paragraphDirection,
        endsParagraph: endsParagraph,
        storage: LineStorage(line: ctLine)
      ))
      widest = max(widest, lineWidth)
      y = grid.round(y + lineHeight)
      start = NSMaxRange(range)
      if start < length {
        y = grid.round(y + (endsParagraph ? style.paragraphSpacing : style.lineSpacing))
      }
      if endsParagraph {
        paragraphStart = start
      }
    }

    return TextLayout(
      lines: lines,
      size: CGSize(width: grid.ceil(widest), height: grid.ceil(y)),
      maximumWidth: width,
      length: length
    )
  }

  /// Widths beyond any screen mean "unbounded"; clamping keeps them usable as cache keys.
  static let unboundedWidth: CGFloat = 100_000

  static func clampedWidth(_ width: CGFloat) -> CGFloat {
    width.isFinite ? min(max(1, width), unboundedWidth) : unboundedWidth
  }

  private static func direction(of string: NSString, from start: Int, style: TextLayoutStyle) -> TextDirection {
    let end = string.rangeOfCharacter(from: .newlines, range: NSRange(location: start, length: string.length - start))
    let paragraphEnd = end.location == NSNotFound ? string.length : end.location
    return TextDirection.firstStrong(
      in: string,
      range: NSRange(location: start, length: paragraphEnd - start),
      fallback: style.fallbackDirection
    )
  }

  private static func endsWithHardBreak(_ string: NSString, range: NSRange) -> Bool {
    guard range.length > 0 else { return false }
    let last = string.character(at: NSMaxRange(range) - 1)
    // \n, \r, line separator, paragraph separator
    return last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029
  }
}

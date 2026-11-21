import CoreGraphics

/// Tile geometry for an album: photos and videos sent together, drawn as one grid in one bubble.
///
/// Tiles keep their order, read in rows (left to right, top to bottom; hosts mirror for
/// right-to-left). Every row spans the full width, so the grid is a rectangle whose outer
/// corners the bubble rounds. Tiles draw aspect-fill, so a row whose natural height is clamped
/// crops its tiles a little instead of leaving gaps.
public struct AlbumMosaic: Equatable, Sendable {
  public struct Tile: Equatable, Sendable {
    /// In the grid's coordinates, origin top-left.
    public var frame: CGRect
    /// Grid corners this tile touches, for rounding.
    public var corners: Corners
    /// Radians, about the tile's centre (a stack's cards behind the front one).
    public var rotation: CGFloat = 0
    /// Not drawn (a stack shows only its first few cards).
    public var isHidden = false
  }

  /// How the album's grid moves inside the bubble.
  public enum Scrolling: Equatable, Sendable {
    /// Everything fits in `size`.
    case none
    /// Scrolls sideways through `contentSize`.
    case free
    /// Scrolls sideways a card at a time, cards this far apart.
    case paging(CGFloat)
  }

  public struct Corners: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let topLeft = Corners(rawValue: 1 << 0)
    public static let topRight = Corners(rawValue: 1 << 1)
    public static let bottomLeft = Corners(rawValue: 1 << 2)
    public static let bottomRight = Corners(rawValue: 1 << 3)
  }

  public struct Metrics: Hashable, Sendable {
    /// The grid's width (the bubble's media width).
    public var width: CGFloat
    /// The tallest the grid may be.
    public var maxHeight: CGFloat
    /// Gap between tiles.
    public var spacing: CGFloat = 2
    /// No row is shorter than this, however many wide photos share it.
    public var minRowHeight: CGFloat = 64
    /// No row is taller than this; a single tall photo in a row is cropped to it.
    public var maxRowHeight: CGFloat

    public init(width: CGFloat, maxHeight: CGFloat, spacing: CGFloat = 2, minRowHeight: CGFloat = 64, maxRowHeight: CGFloat? = nil) {
      self.width = width
      self.maxHeight = maxHeight
      self.spacing = spacing
      self.minRowHeight = minRowHeight
      self.maxRowHeight = maxRowHeight ?? width * 0.75
    }
  }

  public var size: CGSize
  /// One per input item, in input order.
  public var tiles: [Tile]
  /// Item counts per row, top to bottom.
  public var rows: [Int]
  /// The tiles' extent; wider than `size` when the album scrolls.
  public var contentSize: CGSize? = nil
  public var scrolling: Scrolling = .none
  /// Zero: the tiles form one shape whose outer corners the host rounds. Otherwise every tile
  /// rounds its own corners and the host clips nothing (stacks, strips and cards).
  public var tileCornerRadius: CGFloat = 0
  /// Later tiles are drawn under earlier ones (a stack's front card is the first item).
  public var drawsFirstOnTop = false
  /// Shows the item count over the album (a stack, whose other items are hidden).
  public var showsCount = false

  /// Most items in one row.
  public static let maxPerRow = 4

  /// Lays out items with these aspect ratios (width / height; invalid ratios count as square).
  ///
  /// Every split of the items into rows (at most 2^(n-1), 512 for ten) is scored and the best
  /// one kept. A row's natural height fills the width with its items at their aspect ratios.
  /// The score prefers rows near a comfortable height (half the width: two squares side by
  /// side), little cropping, and a grid near its ideal height for its count, and keeps it under
  /// `maxHeight`.
  public static func layout(aspectRatios: [CGFloat], metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    let ratios = aspectRatios.map { $0.isFinite && $0 > 0 ? min(max($0, 0.25), 4) : 1 }
    guard !ratios.isEmpty, metrics.width > 0 else { return AlbumMosaic(size: .zero, tiles: [], rows: []) }

    var best: (score: CGFloat, rows: [Int])?
    for split in splits(count: ratios.count) {
      let score = score(rows: split, ratios: ratios, metrics: metrics)
      if best.map({ score < $0.score }) ?? true { best = (score, split) }
    }
    return place(rows: best?.rows ?? [ratios.count], ratios: ratios, metrics: metrics, grid: grid)
  }

  /// Row sizes, each 1 ... `maxPerRow`, summing to `count`, in order.
  static func splits(count: Int) -> [[Int]] {
    var result: [[Int]] = []
    func extend(_ prefix: [Int], remaining: Int) {
      if remaining == 0 {
        result.append(prefix)
        return
      }
      for size in 1 ... min(maxPerRow, remaining) {
        extend(prefix + [size], remaining: remaining - size)
      }
    }
    extend([], remaining: count)
    return result
  }

  private static func naturalHeight(_ ratios: ArraySlice<CGFloat>, metrics: Metrics) -> CGFloat {
    (metrics.width - metrics.spacing * CGFloat(ratios.count - 1)) / ratios.reduce(0, +)
  }

  private static func clampedHeight(_ natural: CGFloat, metrics: Metrics) -> CGFloat {
    min(max(natural, metrics.minRowHeight), metrics.maxRowHeight)
  }

  static func score(rows: [Int], ratios: [CGFloat], metrics: Metrics) -> CGFloat {
    let comfortable = metrics.width / 2
    var score: CGFloat = 0
    var total = metrics.spacing * CGFloat(rows.count - 1)
    var start = 0
    for count in rows {
      let natural = naturalHeight(ratios[start ..< start + count], metrics: metrics)
      let height = clampedHeight(natural, metrics: metrics)
      total += height
      score += pow((height - comfortable) / comfortable, 2)
      // Cropping: how far the clamp moved the row from its natural height.
      score += 2 * pow((natural - height) / height, 2)
      start += count
    }
    // A grid near a comfortable overall height, so two wide photos stack rather than shrink to a strip.
    let ideal = min(metrics.maxHeight, metrics.width * 0.9)
    score += pow((total - ideal) / ideal, 2)
    if total > metrics.maxHeight {
      score += 10 * pow((total - metrics.maxHeight) / metrics.maxHeight, 2) + 1
    }
    return score
  }

  static func place(rows: [Int], ratios: [CGFloat], metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    var heights = [CGFloat]()
    var start = 0
    for count in rows {
      heights.append(clampedHeight(naturalHeight(ratios[start ..< start + count], metrics: metrics), metrics: metrics))
      start += count
    }
    // Over the cap even so: shrink every row alike (they crop).
    let spacingTotal = metrics.spacing * CGFloat(rows.count - 1)
    let natural = heights.reduce(0, +)
    if natural + spacingTotal > metrics.maxHeight, natural > 0 {
      let factor = max(metrics.maxHeight - spacingTotal, 0) / natural
      heights = heights.map { $0 * factor }
    }

    let width = grid.round(metrics.width)
    var tiles: [Tile] = []
    tiles.reserveCapacity(ratios.count)
    var y: CGFloat = 0
    start = 0
    for (rowIndex, count) in rows.enumerated() {
      let top = grid.round(y)
      let bottom = grid.round(y + heights[rowIndex])
      let rowRatios = ratios[start ..< start + count]
      let available = width - metrics.spacing * CGFloat(count - 1)
      let sum = rowRatios.reduce(0, +)
      var x: CGFloat = 0
      for (offset, ratio) in rowRatios.enumerated() {
        let isLast = offset == count - 1
        let left = grid.round(x)
        // The last tile ends exactly at the edge, whatever rounding did before it.
        let right = isLast ? width : grid.round(x + available * ratio / sum)
        var corners: Corners = []
        if rowIndex == 0, offset == 0 { corners.insert(.topLeft) }
        if rowIndex == 0, isLast { corners.insert(.topRight) }
        if rowIndex == rows.count - 1, offset == 0 { corners.insert(.bottomLeft) }
        if rowIndex == rows.count - 1, isLast { corners.insert(.bottomRight) }
        tiles.append(Tile(frame: CGRect(x: left, y: top, width: right - left, height: bottom - top), corners: corners))
        x += available * ratio / sum + metrics.spacing
      }
      y += heights[rowIndex] + metrics.spacing
      start += count
    }
    let height = tiles.map(\.frame.maxY).max() ?? 0
    return AlbumMosaic(size: CGSize(width: width, height: height), tiles: tiles, rows: rows)
  }
}

public extension AlbumMosaic {
  /// A lone tile at least `width` wide, cropped to it: the photo or video over an album's files,
  /// so a portrait one doesn't narrow the bubble and cut the file names short. Mosaics of more
  /// tiles, or that scroll, are returned as they are.
  func widened(toAtLeast width: CGFloat, grid: PixelGrid) -> AlbumMosaic {
    guard tiles.count == 1, scrolling == .none, size.width < width else { return self }
    var widened = self
    let width = grid.floor(width)
    widened.size.width = width
    widened.tiles[0].frame.size.width = width
    return widened
  }
}

import CoreGraphics
import Foundation

/// The ways an album can be drawn. Every style is a pure function of the items' aspect ratios
/// and the space the bubble offers, so hosts plan and measure albums like any other block.
public enum AlbumLayoutStyle: String, CaseIterable, Sendable {
  /// Telegram's album rules (the default): by count and shape, side by side, stacked, a large
  /// photo beside a column, or one on top of a row; five or more in rows of at most three.
  case telegram
  /// Justified rows: every split into rows is scored, the closest to comfortable kept.
  case rows
  /// Uniform square cells, two or three across; a short last row stretches.
  case grid
  /// The first item large across the top, the rest in a row (or two) under it.
  case featured
  /// A pile of cards like Messages: the first item in front, two more peeking behind it.
  case stack
  /// One row of thumbnails at their aspect ratios that scrolls sideways.
  case strip
  /// Large cards, one at a time, with the next one peeking; swipe to page.
  case cards

  public var title: String {
    switch self {
      case .telegram: "Telegram"
      case .rows: "Rows"
      case .grid: "Grid"
      case .featured: "Featured"
      case .stack: "Stack"
      case .strip: "Strip"
      case .cards: "Cards"
    }
  }
}

public extension AlbumMosaic {
  /// Lays out an album in `style`. `metrics.width` is the widest the album may be.
  static func layout(
    style: AlbumLayoutStyle, aspectRatios: [CGFloat], metrics: Metrics, grid: PixelGrid
  ) -> AlbumMosaic {
    let ratios = aspectRatios.map { $0.isFinite && $0 > 0 ? min(max($0, 0.25), 4) : 1 }
    guard !ratios.isEmpty, metrics.width > 0 else { return AlbumMosaic(size: .zero, tiles: [], rows: []) }
    switch style {
      case .telegram: return telegram(ratios, metrics: metrics, grid: grid)
      case .rows: return layout(aspectRatios: ratios, metrics: metrics, grid: grid)
      case .grid: return uniformGrid(ratios.count, metrics: metrics, grid: grid)
      case .featured: return featured(ratios, metrics: metrics, grid: grid)
      case .stack: return stack(ratios, metrics: metrics, grid: grid)
      case .strip: return strip(ratios, metrics: metrics, grid: grid)
      case .cards: return cards(ratios.count, metrics: metrics, grid: grid)
    }
  }

  // MARK: - Grid

  /// Columns: two for two or four items, three otherwise.
  static func gridColumns(_ count: Int) -> Int {
    count == 2 || count == 4 ? 2 : 3
  }

  static func uniformGrid(_ count: Int, metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    let columns = min(gridColumns(count), count)
    var rows: [Int] = []
    var left = count
    while left > 0 {
      rows.append(min(columns, left))
      left -= columns
    }
    let cell = (metrics.width - metrics.spacing * CGFloat(columns - 1)) / CGFloat(columns)
    return rowsLayout(rows, heights: rows.map { _ in cell }, metrics: metrics, grid: grid)
  }

  // MARK: - Featured

  static func featured(_ ratios: [CGFloat], metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    let count = ratios.count
    // The first item across the top at its aspect, between a wide band and a square.
    let heroHeight = min(max(metrics.width / ratios[0], metrics.width * 0.5), metrics.width * 0.9)
    let rest = count - 1
    // The rest in rows of up to four (a second row when there are more than four).
    var rows = [1]
    if rest > 0 {
      let perRow = rest <= 4 ? rest : Int((Double(rest) / 2).rounded(.up))
      var left = rest
      while left > 0 {
        rows.append(min(perRow, left))
        left -= perRow
      }
    }
    let heights = rows.enumerated().map { index, itemsInRow -> CGFloat in
      if index == 0 { return heroHeight }
      let cell = (metrics.width - metrics.spacing * CGFloat(itemsInRow - 1)) / CGFloat(itemsInRow)
      return min(cell, metrics.width * 0.4)
    }
    return rowsLayout(rows, heights: heights, metrics: metrics, grid: grid)
  }

  /// Rows of equal-width cells at the given heights, spanning the width; scaled down together
  /// when over `maxHeight`.
  static func rowsLayout(_ rows: [Int], heights: [CGFloat], metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    var heights = heights
    let spacingTotal = metrics.spacing * CGFloat(rows.count - 1)
    let total = heights.reduce(0, +)
    if total + spacingTotal > metrics.maxHeight, total > 0 {
      let factor = max(metrics.maxHeight - spacingTotal, 0) / total
      heights = heights.map { $0 * factor }
    }
    let width = grid.round(metrics.width)
    var tiles: [Tile] = []
    var y: CGFloat = 0
    for (rowIndex, count) in rows.enumerated() {
      let top = grid.round(y)
      let bottom = grid.round(y + heights[rowIndex])
      let cell = (width - metrics.spacing * CGFloat(count - 1)) / CGFloat(count)
      for column in 0 ..< count {
        let isLast = column == count - 1
        let left = grid.round(CGFloat(column) * (cell + metrics.spacing))
        let right = isLast ? width : grid.round(CGFloat(column) * (cell + metrics.spacing) + cell)
        var corners: Corners = []
        if rowIndex == 0, column == 0 { corners.insert(.topLeft) }
        if rowIndex == 0, isLast { corners.insert(.topRight) }
        if rowIndex == rows.count - 1, column == 0 { corners.insert(.bottomLeft) }
        if rowIndex == rows.count - 1, isLast { corners.insert(.bottomRight) }
        tiles.append(Tile(frame: CGRect(x: left, y: top, width: right - left, height: bottom - top), corners: corners))
      }
      y += heights[rowIndex] + metrics.spacing
    }
    return AlbumMosaic(size: CGSize(width: width, height: tiles.map(\.frame.maxY).max() ?? 0), tiles: tiles, rows: rows)
  }

  // MARK: - Stack

  /// Cards drawn behind the front one.
  static let stackDepth = 2

  static func stack(_ ratios: [CGFloat], metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    // Room around the cards for the ones behind to peek out, rotated.
    let inset: CGFloat = 14
    let cardWidth = grid.round(metrics.width * 0.8)
    let cardHeight = grid.round(min(max(cardWidth / ratios[0], cardWidth * 0.7), min(cardWidth * 1.3, metrics.maxHeight - 2 * inset)))
    let size = CGSize(width: grid.round(metrics.width), height: cardHeight + 2 * inset)
    let front = CGRect(x: grid.round((size.width - cardWidth) / 2), y: inset, width: cardWidth, height: cardHeight)
    let angles: [CGFloat] = [0, 5, -4]
    let shifts: [CGFloat] = [0, 10, -10]
    let tiles = ratios.indices.map { index -> Tile in
      let depth = min(index, stackDepth)
      return Tile(
        frame: front.offsetBy(dx: shifts[depth], dy: 0),
        corners: [.topLeft, .topRight, .bottomLeft, .bottomRight],
        rotation: angles[depth] * .pi / 180,
        isHidden: index > stackDepth
      )
    }
    return AlbumMosaic(
      size: size, tiles: tiles, rows: [ratios.count], tileCornerRadius: 16, drawsFirstOnTop: true,
      showsCount: ratios.count > 1
    )
  }

  // MARK: - Strip

  static func strip(_ ratios: [CGFloat], metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    // Thumbnails: several show at once, the rest scroll in.
    let height = grid.round(min(metrics.width * 0.45, metrics.maxHeight))
    var x: CGFloat = 0
    let tiles = ratios.map { ratio -> Tile in
      let width = grid.round(min(max(height * ratio, height * 0.6), height * 1.4))
      defer { x += width + 4 }
      return Tile(frame: CGRect(x: grid.round(x), y: 0, width: width, height: height), corners: [])
    }
    let contentWidth = (tiles.last?.frame.maxX ?? 0)
    let width = grid.round(min(metrics.width, contentWidth))
    return AlbumMosaic(
      size: CGSize(width: width, height: height), tiles: tiles, rows: [ratios.count],
      contentSize: CGSize(width: contentWidth, height: height),
      scrolling: contentWidth > width ? .free : .none, tileCornerRadius: 12
    )
  }

  // MARK: - Cards

  static func cards(_ count: Int, metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    let spacing: CGFloat = 8
    // The next card peeks in from the trailing edge.
    let cardWidth = grid.round(count > 1 ? metrics.width * 0.84 : metrics.width)
    let cardHeight = grid.round(min(cardWidth * 1.1, metrics.maxHeight))
    let tiles = (0 ..< count).map { index in
      Tile(
        frame: CGRect(x: grid.round(CGFloat(index) * (cardWidth + spacing)), y: 0, width: cardWidth, height: cardHeight),
        corners: []
      )
    }
    let contentWidth = tiles.last?.frame.maxX ?? 0
    let width = grid.round(metrics.width)
    return AlbumMosaic(
      size: CGSize(width: width, height: cardHeight), tiles: tiles, rows: [count],
      contentSize: CGSize(width: contentWidth, height: cardHeight),
      scrolling: count > 1 ? .paging(cardWidth + spacing) : .none, tileCornerRadius: 16
    )
  }
}

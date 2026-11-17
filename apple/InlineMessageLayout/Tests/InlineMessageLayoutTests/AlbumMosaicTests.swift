import CoreGraphics
import Testing
@testable import InlineMessageLayout

@Suite("Album mosaic")
struct AlbumMosaicTests {
  let grid = PixelGrid(scale: 3)
  let metrics = AlbumMosaic.Metrics(width: 280, maxHeight: 360)

  private func layout(_ ratios: [CGFloat]) -> AlbumMosaic {
    AlbumMosaic.layout(aspectRatios: ratios, metrics: metrics, grid: grid)
  }

  /// Rows span the width, keep order, never overlap, stay on pixels and under the cap.
  private func checkInvariants(_ mosaic: AlbumMosaic, count: Int) {
    #expect(mosaic.tiles.count == count)
    #expect(mosaic.rows.reduce(0, +) == count)
    #expect(mosaic.size.width == 280)
    #expect(mosaic.size.height <= 360 + 0.01)
    var index = 0
    var previousBottom: CGFloat = -1
    for count in mosaic.rows {
      let row = mosaic.tiles[index ..< index + count]
      #expect(row.first?.frame.minX == 0)
      #expect(row.last?.frame.maxX == 280)
      #expect(Set(row.map(\.frame.minY)).count == 1)
      #expect(row.first!.frame.minY > previousBottom)
      for (left, right) in zip(row, row.dropFirst()) {
        #expect(right.frame.minX > left.frame.maxX)
      }
      for tile in row {
        #expect(grid.isAligned(tile.frame))
        #expect(tile.frame.width > 0 && tile.frame.height > 0)
      }
      previousBottom = row.first!.frame.maxY
      index += count
    }
  }

  @Test("two squares sit side by side; two wide photos stack")
  func pairs() {
    let squares = layout([1, 1])
    checkInvariants(squares, count: 2)
    #expect(squares.rows == [2])

    let wide = layout([16.0 / 9, 16.0 / 9])
    checkInvariants(wide, count: 2)
    #expect(wide.rows == [1, 1])

    let portraits = layout([0.75, 0.75])
    #expect(portraits.rows == [2])
  }

  @Test("every count from two to ten fits, for mixed shapes")
  func counts() {
    let shapes: [CGFloat] = [1, 1.5, 0.66, 1.78, 0.56, 1, 1.33, 0.75, 2.4, 1]
    for count in 2 ... 10 {
      let mosaic = layout(Array(shapes.prefix(count)))
      checkInvariants(mosaic, count: count)
      #expect(mosaic.rows.allSatisfy { $0 <= AlbumMosaic.maxPerRow })
    }
  }

  @Test("tall portraits alone are capped and cropped instead of growing past the cap")
  func tall() {
    let mosaic = layout([0.3, 0.3, 0.3])
    checkInvariants(mosaic, count: 3)
  }

  @Test("outer corners belong to the outer tiles")
  func corners() {
    let mosaic = layout([1, 1, 1, 1])
    checkInvariants(mosaic, count: 4)
    let corners = mosaic.tiles.map(\.corners)
    #expect(corners.reduce(into: AlbumMosaic.Corners()) { $0.formUnion($1) } == [.topLeft, .topRight, .bottomLeft, .bottomRight])
    #expect(corners.first!.contains(.topLeft))
    #expect(corners.last!.contains(.bottomRight))
  }

  @Test("splits enumerate every ordered row split with at most four per row")
  func splits() {
    #expect(AlbumMosaic.splits(count: 3) == [[1, 1, 1], [1, 2], [2, 1], [3]])
    #expect(AlbumMosaic.splits(count: 10).allSatisfy { $0.reduce(0, +) == 10 && $0.allSatisfy { $0 <= 4 } })
  }

  @Test("bad ratios count as square")
  func badRatios() {
    checkInvariants(layout([.nan, 0, -1, .infinity]), count: 4)
  }

  @Test("every style fits its counts: one tile per item, inside its content, within the caps")
  func styles() {
    let shapes: [CGFloat] = [1.5, 0.66, 1, 1.78, 0.56, 1, 1.33, 0.75, 2.4, 1]
    for style in AlbumLayoutStyle.allCases {
      for count in 2 ... 10 {
        let mosaic = AlbumMosaic.layout(
          style: style, aspectRatios: Array(shapes.prefix(count)), metrics: metrics, grid: grid
        )
        let content = mosaic.contentSize ?? mosaic.size
        #expect(mosaic.tiles.count == count, "\(style) \(count)")
        #expect(mosaic.size.width <= 280 + 0.01, "\(style) \(count)")
        #expect(mosaic.size.height <= 360 + 0.01, "\(style) \(count)")
        for tile in mosaic.tiles where tile.rotation == 0 {
          #expect(tile.frame.minX >= -0.01 && tile.frame.maxX <= content.width + 0.01, "\(style) \(count)")
          #expect(tile.frame.minY >= -0.01 && tile.frame.maxY <= content.height + 0.01, "\(style) \(count)")
          #expect(tile.frame.width > 0 && tile.frame.height > 0)
        }
        if mosaic.scrolling == .none {
          #expect(content.width <= mosaic.size.width + 0.01, "\(style) \(count)")
        }
      }
    }
  }

  @Test("a grid is two across for two or four, three otherwise; a stack shows three cards")
  func gridAndStack() {
    #expect(AlbumMosaic.layout(style: .grid, aspectRatios: [1, 1, 1, 1], metrics: metrics, grid: grid).rows == [2, 2])
    #expect(AlbumMosaic.layout(style: .grid, aspectRatios: Array(repeating: 1, count: 5), metrics: metrics, grid: grid).rows == [3, 2])
    let stack = AlbumMosaic.layout(style: .stack, aspectRatios: Array(repeating: 1, count: 5), metrics: metrics, grid: grid)
    #expect(stack.tiles.filter { !$0.isHidden }.count == 3)
    #expect(stack.drawsFirstOnTop && stack.showsCount && stack.tileCornerRadius > 0)
    let cards = AlbumMosaic.layout(style: .cards, aspectRatios: [1, 1, 1], metrics: metrics, grid: grid)
    if case .paging = cards.scrolling {} else { Issue.record("cards page") }
    #expect((cards.contentSize?.width ?? 0) > cards.size.width)
  }

  // MARK: Telegram style

  private func telegram(_ ratios: [CGFloat]) -> AlbumMosaic {
    AlbumMosaic.layout(style: .telegram, aspectRatios: ratios, metrics: metrics, grid: grid)
  }

  @Test("Telegram style: two squares side by side, two wide photos stacked, mixed pairs in proportion")
  func telegramPairs() {
    #expect(telegram([1, 1]).rows == [2])
    let wide = telegram([16.0 / 9, 16.0 / 9])
    #expect(wide.rows == [1, 1])
    #expect(wide.tiles.allSatisfy { $0.frame.width == 280 })
    let mixed = telegram([1.5, 0.66])
    #expect(mixed.rows == [2])
    #expect(mixed.tiles[0].frame.width > mixed.tiles[1].frame.width)
  }

  @Test("Telegram style: a narrow first photo of three is a column beside two stacked; otherwise it spans the top")
  func telegramThree() {
    let column = telegram([0.6, 1, 1])
    #expect(column.tiles[0].frame.minX == 0 && column.tiles[0].frame.height == column.size.height)
    #expect(column.tiles[1].frame.minX == column.tiles[2].frame.minX)
    #expect(column.tiles[1].frame.maxY < column.tiles[2].frame.minY)

    let top = telegram([1.5, 1, 1])
    #expect(top.tiles[0].frame.width == top.size.width)
    #expect(top.tiles[1].frame.minY == top.tiles[2].frame.minY)
  }

  @Test("Telegram style: four is one over three when the first is wide, else a column beside three")
  func telegramFour() {
    let over = telegram([1.6, 1, 1, 1])
    #expect(over.rows == [1, 3])
    #expect(over.tiles[3].frame.maxX == over.size.width)
    let beside = telegram([0.7, 1, 1, 1])
    #expect(beside.tiles[0].frame.height == beside.size.height)
    #expect(Set(beside.tiles.dropFirst().map(\.frame.minX)).count == 1)
  }

  @Test("Telegram style: five or more go into two to four rows of at most three, spanning the width")
  func telegramMany() {
    for count in 5 ... 10 {
      let mosaic = telegram(Array(repeating: 1.3, count: count))
      checkInvariants(mosaic, count: count)
      #expect(mosaic.rows.count >= 2 && mosaic.rows.count <= 4, "\(count)")
      #expect(mosaic.rows.allSatisfy { $0 <= 4 }, "\(count)")
    }
    // A very wide photo sends even three to the row search.
    #expect(telegram([3, 1, 1]).rows.allSatisfy { $0 <= 3 })
  }

  @Test("Telegram style: extreme shapes never give an empty or negative tile")
  func telegramExtremes() {
    let wide = AlbumMosaic.Metrics(width: 320, maxHeight: 405)
    for ratios: [CGFloat] in [[1.5, 0.25, 0.25, 2], [2, 0.25], [0.25, 4, 0.25], [1.21, 0.26, 0.26, 1.99]] {
      let mosaic = AlbumMosaic.layout(style: .telegram, aspectRatios: ratios, metrics: wide, grid: grid)
      #expect(mosaic.tiles.allSatisfy { $0.frame.width >= 40 && $0.frame.height > 0 }, "\(ratios)")
    }
  }
}


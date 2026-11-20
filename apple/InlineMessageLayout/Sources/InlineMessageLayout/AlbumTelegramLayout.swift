import CoreGraphics
import Foundation

/// Albums arranged roughly the way Telegram arranges them (Mo: the layout to aim for, not a 1:1
/// clone).
///
/// The rules:
/// - Each item is wide (ratio over 1.2), narrow (under 0.8) or square.
/// - Two, three or four items, none wider than 2:1, get a fixed arrangement by count and shape:
///   - two: stacked when both are wide and wider than the box, side by side and equal when both
///     are wide or both square, otherwise side by side in proportion;
///   - three: a narrow first item is a full-height column beside the other two stacked;
///     otherwise the first spans the top and the other two share the row under it;
///   - four: a wide first item spans the top over a row of three; otherwise it is a full-height
///     column beside the other three stacked.
/// - Five or more (or any item wider than 2:1): ratios are evened out (towards 1, kept within
///   2:3 to 17:10), and every split into two to four rows of at most three is tried; the one
///   whose height is closest to a 3:4 box wins, with splits that put more items in an upper row
///   than the next, or that make a row too short, counted half again as far off.
///
/// The box is at most `metrics.width` wide and `metrics.maxHeight` tall; tiles are
/// `metrics.spacing` apart. The album can come out narrower than the box (a tall column beside a
/// short one); rows that would end up taller than the box shrink to it (tiles crop).
public extension AlbumMosaic {
  static func telegram(_ ratios: [CGFloat], metrics: Metrics, grid: PixelGrid) -> AlbumMosaic {
    let box = CGSize(width: metrics.width, height: metrics.maxHeight)
    var frames = TelegramAlbumRules(box: box, spacing: metrics.spacing, ratios: ratios).frames()
    // Rows aiming at 3:4 can pass a short box: scale down vertically (aspect-fill tiles crop).
    let height = frames.map(\.maxY).max() ?? 0
    if height > box.height, height > 0 {
      let factor = box.height / height
      frames = frames.map { CGRect(x: $0.minX, y: $0.minY * factor, width: $0.width, height: $0.height * factor) }
    }
    return snapped(frames, grid: grid)
  }

  /// Tiles for frames in the album's coordinates, on pixels, with the corners each one touches.
  private static func snapped(_ frames: [CGRect], grid: PixelGrid) -> AlbumMosaic {
    let rounded = frames.map(grid.round)
    let width = rounded.map(\.maxX).max() ?? 0
    let height = rounded.map(\.maxY).max() ?? 0
    let tiles = rounded.map { frame -> Tile in
      var corners: Corners = []
      let top = frame.minY < 0.5
      let bottom = frame.maxY > height - 0.5
      let left = frame.minX < 0.5
      let right = frame.maxX > width - 0.5
      if top, left { corners.insert(.topLeft) }
      if top, right { corners.insert(.topRight) }
      if bottom, left { corners.insert(.bottomLeft) }
      if bottom, right { corners.insert(.bottomRight) }
      return Tile(frame: frame, corners: corners)
    }
    // Runs of tiles that share a top edge, in order (a column's tiles are runs of one).
    var rows: [Int] = []
    for (index, frame) in rounded.enumerated() {
      if index > 0, abs(frame.minY - rounded[index - 1].minY) < 0.5 {
        rows[rows.count - 1] += 1
      } else {
        rows.append(1)
      }
    }
    return AlbumMosaic(size: CGSize(width: width, height: height), tiles: tiles, rows: rows)
  }
}

/// The arithmetic behind `AlbumMosaic.telegram`, one arrangement per case.
struct TelegramAlbumRules {
  enum Shape: Character {
    case wide = "w"
    case narrow = "n"
    case square = "q"
  }

  let box: CGSize
  let spacing: CGFloat
  let ratios: [CGFloat]
  let shapes: [Shape]
  let average: CGFloat
  /// Any item wider than 2:1 sends every count to the row search.
  let hasVeryWide: Bool

  static let minimumWidth: CGFloat = 68
  static let minimumHeight: CGFloat = 81

  init(box: CGSize, spacing: CGFloat, ratios: [CGFloat]) {
    self.box = box
    self.spacing = spacing
    self.ratios = ratios
    shapes = ratios.map { $0 > 1.2 ? .wide : $0 < 0.8 ? .narrow : .square }
    average = ratios.isEmpty ? 1 : ratios.reduce(0, +) / CGFloat(ratios.count)
    hasVeryWide = ratios.contains { $0 > 2 }
  }

  func frames() -> [CGRect] {
    guard !hasVeryWide else { return rowSearch() }
    switch ratios.count {
      case 1: return [CGRect(origin: .zero, size: fit(ratios[0]))]
      case 2: return pair()
      case 3: return triple()
      case 4: return quad()
      default: return rowSearch()
    }
  }

  private func fit(_ ratio: CGFloat) -> CGSize {
    let width = min(box.width, box.height * ratio)
    return CGSize(width: width, height: width / ratio)
  }

  // MARK: - Two

  private func pair() -> [CGRect] {
    let (a, b) = (ratios[0], ratios[1])
    let bothWide = shapes[0] == .wide && shapes[1] == .wide
    let bothSquare = shapes[0] == .square && shapes[1] == .square
    if bothWide, average > 1.4 * (box.width / box.height), b - a < 0.2 {
      // Stacked, full width.
      let height = floor(min(box.width / a, box.width / b, (box.height - spacing) / 2))
      return [
        CGRect(x: 0, y: 0, width: box.width, height: height),
        CGRect(x: 0, y: height + spacing, width: box.width, height: height),
      ]
    }
    if bothWide || bothSquare {
      // Side by side, equal.
      let width = (box.width - spacing) / 2
      let height = floor(min(width / a, width / b, box.height))
      return [
        CGRect(x: 0, y: 0, width: width, height: height),
        CGRect(x: width + spacing, y: 0, width: width, height: height),
      ]
    }
    // Side by side, in proportion to their shapes, the narrower never a sliver.
    let available = box.width - spacing
    let second = floor(max(0.3 * available, min(0.5 * available, (available / a / (1 / a + 1 / b)).rounded())))
    let first = box.width - second - spacing
    let height = floor(min(box.height, min(first / a, second / b).rounded()))
    return [
      CGRect(x: 0, y: 0, width: first, height: height),
      CGRect(x: first + spacing, y: 0, width: second, height: height),
    ]
  }

  // MARK: - Three

  private func triple() -> [CGRect] {
    let (a, b, c) = (ratios[0], ratios[1], ratios[2])
    if shapes[0] == .narrow {
      // A full-height column on the left, two stacked on the right.
      let leftHeight = box.height
      let thirdHeight = min((box.height - spacing) / 2, (b * (box.width - spacing) / (c + b)).rounded())
      let secondHeight = box.height - thirdHeight - spacing
      let rightWidth = max(
        Self.minimumWidth,
        min((box.width - spacing) / 2, min(thirdHeight * c, secondHeight * b).rounded())
      )
      let leftWidth = min(leftHeight * a, box.width - spacing - rightWidth).rounded()
      return [
        CGRect(x: 0, y: 0, width: leftWidth, height: leftHeight),
        CGRect(x: leftWidth + spacing, y: 0, width: rightWidth, height: secondHeight),
        CGRect(x: leftWidth + spacing, y: secondHeight + spacing, width: rightWidth, height: thirdHeight),
      ]
    }
    // The first across the top, two side by side under it.
    let topHeight = floor(min(box.width / a, (box.height - spacing) * 0.66))
    let half = (box.width - spacing) / 2
    let bottomHeight = min(box.height - topHeight - spacing, min(half / b, half / c).rounded())
    return [
      CGRect(x: 0, y: 0, width: box.width, height: topHeight),
      CGRect(x: 0, y: topHeight + spacing, width: half, height: bottomHeight),
      CGRect(x: half + spacing, y: topHeight + spacing, width: half, height: bottomHeight),
    ]
  }

  // MARK: - Four

  private func quad() -> [CGRect] {
    let (a, b, c, d) = (ratios[0], ratios[1], ratios[2], ratios[3])
    if shapes[0] == .wide {
      // The first across the top, three side by side under it.
      let topHeight = min(box.width / a, (box.height - spacing) * 0.66).rounded()
      let rowWidth = box.width - 2 * spacing
      var height = (rowWidth / (b + c + d)).rounded()
      let leftWidth = max(Self.minimumWidth, min(rowWidth * 0.4, height * b))
      // The right one never squeezes the middle one under the minimum.
      let rightWidth = min(max(max(Self.minimumWidth, rowWidth * 0.33), height * d), rowWidth - leftWidth - Self.minimumWidth)
      let middleWidth = box.width - leftWidth - rightWidth - 2 * spacing
      height = max(Self.minimumHeight, min(box.height - topHeight - spacing, height))
      let y = topHeight + spacing
      return [
        CGRect(x: 0, y: 0, width: box.width, height: topHeight),
        CGRect(x: 0, y: y, width: leftWidth, height: height),
        CGRect(x: leftWidth + spacing, y: y, width: middleWidth, height: height),
        CGRect(x: leftWidth + middleWidth + 2 * spacing, y: y, width: rightWidth, height: height),
      ]
    }
    // A full-height column on the left, three stacked on the right.
    let height = box.height
    let leftWidth = min(height * a, (box.width - spacing) * 0.6).rounded()
    var width = ((box.height - 2 * spacing) / (1 / b + 1 / c + 1 / d)).rounded()
    let firstHeight = floor(width / b)
    let secondHeight = floor(width / c)
    let thirdHeight = height - firstHeight - secondHeight - 2 * spacing
    width = max(Self.minimumWidth, min(box.width - leftWidth - spacing, width))
    let x = leftWidth + spacing
    return [
      CGRect(x: 0, y: 0, width: leftWidth, height: height),
      CGRect(x: x, y: 0, width: width, height: firstHeight),
      CGRect(x: x, y: firstHeight + spacing, width: width, height: secondHeight),
      CGRect(x: x, y: firstHeight + secondHeight + 2 * spacing, width: width, height: thirdHeight),
    ]
  }

  // MARK: - Five or more

  /// Ratios evened out for rows: towards landscape when the album is mostly wide, towards
  /// portrait otherwise, never past 2:3 or 17:10.
  var evenedRatios: [CGFloat] {
    ratios.map { ratio in
      let leaning = average > 1.1 ? max(1, ratio) : min(1, ratio)
      return min(max(leaning, 2.0 / 3.0), 1.7)
    }
  }

  /// Every split of `count` items into two to four rows of at most three (the middle of three
  /// rows may take four when the album is mostly portrait).
  func rowSplits(count: Int) -> [[Int]] {
    var splits: [[Int]] = []
    func extend(_ prefix: [Int], remaining: Int) {
      let rows = prefix.count
      if remaining == 0 {
        if (2 ... 4).contains(rows) { splits.append(prefix) }
        return
      }
      guard rows < 4 else { return }
      for size in 1 ... min(4, remaining) {
        extend(prefix + [size], remaining: remaining - size)
      }
    }
    extend([], remaining: count)
    return splits.filter { split in
      split.enumerated().allSatisfy { index, size in
        let middleOfThree = split.count == 3 && index == 1
        return size <= (middleOfThree && average < 0.85 ? 4 : 3)
      }
    }
  }

  private func rowSearch() -> [CGRect] {
    let ratios = evenedRatios
    func rowHeight(_ slice: ArraySlice<CGFloat>) -> CGFloat {
      (box.width - CGFloat(slice.count - 1) * spacing) / slice.reduce(0, +)
    }
    func heights(_ split: [Int]) -> [CGFloat] {
      var start = 0
      return split.map { count in
        defer { start += count }
        return rowHeight(ratios[start ..< start + count])
      }
    }
    let target = floor(box.width / 3 * 4)
    var best: (split: [Int], heights: [CGFloat], distance: CGFloat)?
    for split in rowSplits(count: ratios.count) {
      let rowHeights = heights(split)
      let spacingTotal = spacing * CGFloat(split.count - 1)
      let total = spacingTotal + rowHeights.reduce(0) { $0 + floor($1) }
      var distance = abs(total - target)
      // More items in an upper row than the one under it looks top-heavy.
      if zip(split, split.dropFirst()).contains(where: { $0 > $1 }) { distance *= 1.5 }
      // A row so short its tiles turn into slivers.
      if (rowHeights.min() ?? 0) < Self.minimumWidth { distance *= 1.5 }
      if best.map({ distance < $0.distance }) ?? true { best = (split, rowHeights, distance) }
    }
    guard let best else { return [] }

    var frames: [CGRect] = []
    var y: CGFloat = 0
    var index = 0
    for (row, count) in best.split.enumerated() {
      let height = best.heights[row]
      var x: CGFloat = 0
      for column in 0 ..< count {
        // The last tile in a row ends at the album's edge, whatever rounding did before it.
        let width = column == count - 1 ? box.width - x : ratios[index] * height
        frames.append(CGRect(x: x, y: y, width: width, height: height))
        x += width + spacing
        index += 1
      }
      y += height + spacing
    }
    return frames
  }
}

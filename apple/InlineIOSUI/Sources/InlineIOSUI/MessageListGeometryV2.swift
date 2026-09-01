import CoreGraphics

/// Exact, upright row geometry. Preparation happens before this value reaches a collection layout.
/// Coordinates describe the unobscured viewport; the host owns keyboard/chrome placement.
public struct MessageListGeometryV2: Equatable, Sendable {
  public struct Item: Equatable, Sendable {
    public let id: Int64
    public let height: CGFloat

    public init(id: Int64, height: CGFloat) {
      self.id = id
      self.height = height
    }
  }

  public struct Row: Equatable, Sendable {
    public let id: Int64
    public let frame: CGRect
  }

  public struct Anchor: Equatable, Sendable {
    public let id: Int64
    public let localY: CGFloat
    public let viewportY: CGFloat
  }

  public let rows: [Row]
  public let contentSize: CGSize
  public let viewportHeight: CGFloat
  private let indexByID: [Int64: Int]

  public init?(
    items: [Item],
    width: CGFloat,
    viewportHeight: CGFloat,
    spacing: CGFloat = 4,
    padding: CGFloat = 8,
    displayScale: CGFloat = 1
  ) {
    guard width.isFinite, width > 0,
          viewportHeight.isFinite, viewportHeight > 0,
          spacing.isFinite, spacing >= 0,
          padding.isFinite, padding >= 0,
          displayScale.isFinite, displayScale > 0,
          items.allSatisfy({ $0.height.isFinite && $0.height > 0 }),
          Set(items.map(\.id)).count == items.count
    else { return nil }

    let heights = items.map { ceil($0.height * displayScale) / displayScale }
    guard heights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
    let naturalHeight = items.isEmpty ? 0 : heights.reduce(0, +)
      + CGFloat(max(0, items.count - 1)) * spacing + padding * 2
    guard naturalHeight.isFinite else { return nil }

    var y = padding + max(0, viewportHeight - naturalHeight)
    var rows: [Row] = []
    rows.reserveCapacity(items.count)
    for (index, item) in items.enumerated() {
      let frame = CGRect(x: 0, y: y, width: width, height: heights[index])
      guard frame.minY.isFinite, frame.maxY.isFinite else { return nil }
      rows.append(Row(id: item.id, frame: frame))
      y += heights[index] + spacing
    }
    self.rows = rows
    contentSize = CGSize(width: width, height: max(viewportHeight, naturalHeight))
    self.viewportHeight = viewportHeight
    indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
  }

  public var maximumOffsetY: CGFloat {
    max(0, contentSize.height - viewportHeight)
  }

  public func clampedOffset(_ offset: CGFloat) -> CGFloat {
    guard offset.isFinite else { return 0 }
    return min(maximumOffsetY, max(0, offset))
  }

  public func isFollowingBottom(at offset: CGFloat, threshold: CGFloat = 44) -> Bool {
    offset.isFinite && threshold.isFinite && threshold >= 0
      && maximumOffsetY - clampedOffset(offset) <= threshold
  }

  public func frame(for id: Int64) -> CGRect? {
    indexByID[id].map { rows[$0].frame }
  }

  public func index(for id: Int64) -> Int? {
    indexByID[id]
  }

  /// The layout's scroll-time query only searches already prepared numeric frames.
  public func indices(intersecting rect: CGRect) -> Range<Int> {
    guard rect.minY.isFinite, rect.maxY.isFinite, rect.height > 0 else { return 0 ..< 0 }
    var low = 0
    var high = rows.count
    while low < high {
      let middle = (low + high) / 2
      if rows[middle].frame.maxY <= rect.minY {
        low = middle + 1
      } else {
        high = middle
      }
    }
    let first = low
    while low < rows.count, rows[low].frame.minY < rect.maxY {
      low += 1
    }
    return first ..< low
  }

  public func anchor(at offset: CGFloat) -> Anchor? {
    guard offset.isFinite else { return nil }
    let viewport = CGRect(x: 0, y: offset, width: contentSize.width, height: viewportHeight)
    guard let index = indices(intersecting: viewport).first else { return nil }
    let row = rows[index]
    let localY = max(0, offset - row.frame.minY)
    return Anchor(id: row.id, localY: localY, viewportY: row.frame.minY + localY - offset)
  }

  public func offset(preserving anchor: Anchor, from previous: Self) -> CGFloat {
    guard anchor.localY.isFinite, anchor.localY >= 0, anchor.viewportY.isFinite else { return 0 }
    guard let oldIndex = previous.indexByID[anchor.id] else { return 0 }
    let oldFrame = previous.rows[oldIndex].frame
    let oldOffset = oldFrame.minY + anchor.localY - anchor.viewportY
    if let frame = frame(for: anchor.id) {
      let localY = min(anchor.localY, frame.height)
      return clampedOffset(frame.minY + localY - anchor.viewportY)
    }

    // Chronological order: prefer the next newer survivor, then an older one.
    let candidate = previous.rows.dropFirst(oldIndex + 1).first { indexByID[$0.id] != nil }
      ?? previous.rows.prefix(oldIndex).reversed().first { indexByID[$0.id] != nil }
    if let candidate, let frame = frame(for: candidate.id) {
      return clampedOffset(frame.minY - (candidate.frame.minY - oldOffset))
    }
    return clampedOffset(oldOffset)
  }
}

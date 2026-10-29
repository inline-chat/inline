import CoreGraphics

/// Places a message context menu: the reaction bar, the lifted bubble and the actions in one
/// column that scrolls when it is taller than the screen, the way Telegram iOS places an
/// extracted message.
///
/// The bubble starts where it sits in the chat. It moves down below the top inset (and the
/// reaction bar), then up until the actions fit above the bottom inset; if the column is still
/// too tall, its top stays pinned and the column scrolls, opening at the bottom so the actions
/// are on screen.
///
/// Coordinates are y-down. `source` is in the viewport's coordinates; results are in the
/// scrolling content's coordinates, which equal the viewport's at a zero offset.
public enum ContextMenuLayout {
  /// The bubble edge the actions and reaction bar line up with.
  public enum Alignment: Hashable, Sendable {
    case left
    case right
  }

  public struct Insets: Hashable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
      self.top = top
      self.left = left
      self.bottom = bottom
      self.right = right
    }

    public static let zero = Insets()
  }

  public struct Metrics: Hashable, Sendable {
    /// Room between the safe area's top and the column.
    public var topInset: CGFloat
    /// Room between the column and the safe area's bottom.
    public var bottomInset: CGFloat
    /// Minimum distance from the screen's sides.
    public var sideInset: CGFloat
    public var previewMenuSpacing: CGFloat
    public var accessoryPreviewSpacing: CGFloat

    public init(
      topInset: CGFloat = 8,
      bottomInset: CGFloat = 10,
      sideInset: CGFloat = 12,
      previewMenuSpacing: CGFloat = 8,
      accessoryPreviewSpacing: CGFloat = 8
    ) {
      self.topInset = topInset
      self.bottomInset = bottomInset
      self.sideInset = sideInset
      self.previewMenuSpacing = previewMenuSpacing
      self.accessoryPreviewSpacing = accessoryPreviewSpacing
    }

    public static let standard = Metrics()
  }

  public struct Input: Equatable, Sendable {
    /// Size of the scrolling area: the screen above the keyboard.
    public var viewport: CGSize
    /// Safe area within the viewport. The bottom is zero when a keyboard ends the viewport.
    public var safeInsets: Insets
    /// The bubble's frame in the chat, in viewport coordinates.
    public var source: CGRect
    public var menuSize: CGSize
    public var accessorySize: CGSize?
    public var alignment: Alignment
    public var metrics: Metrics
    public var grid: PixelGrid

    public init(
      viewport: CGSize,
      safeInsets: Insets,
      source: CGRect,
      menuSize: CGSize,
      accessorySize: CGSize? = nil,
      alignment: Alignment,
      metrics: Metrics = .standard,
      grid: PixelGrid = PixelGrid(scale: 3)
    ) {
      self.viewport = viewport
      self.safeInsets = safeInsets
      self.source = source
      self.menuSize = menuSize
      self.accessorySize = accessorySize
      self.alignment = alignment
      self.metrics = metrics
      self.grid = grid
    }
  }

  public struct Result: Equatable, Sendable {
    /// Height is at least the viewport's.
    public var contentSize: CGSize
    /// Initial scroll offset: the bottom of the column, so the actions are visible.
    public var contentOffsetY: CGFloat
    public var preview: CGRect
    public var menu: CGRect
    public var accessory: CGRect?
    /// The point of the menu that stays put while it scales in, in unit coordinates: the
    /// top corner on the aligned side, where it meets the bubble.
    public var menuAnchor: CGPoint
    public var isScrollable: Bool

    /// Where `rect`, in viewport coordinates, sits in content coordinates at the initial offset.
    public func contentRect(fromViewport rect: CGRect) -> CGRect {
      rect.offsetBy(dx: 0, dy: contentOffsetY)
    }
  }

  public static func plan(_ input: Input) -> Result {
    let metrics = input.metrics
    let viewport = input.viewport
    let safe = input.safeInsets
    let grid = input.grid

    let minX = safe.left + metrics.sideInset
    let maxX = max(minX, viewport.width - safe.right - metrics.sideInset)
    let availableWidth = maxX - minX

    let accessorySize = input.accessorySize.map {
      CGSize(width: min($0.width, availableWidth), height: $0.height)
    }
    let accessoryRoom = accessorySize.map { $0.height + metrics.accessoryPreviewSpacing } ?? 0
    let top = safe.top + metrics.topInset + accessoryRoom
    let bottom = viewport.height - safe.bottom - metrics.bottomInset
    let menuSize = CGSize(width: min(input.menuSize.width, availableWidth), height: input.menuSize.height)

    var preview = input.source
    // Keep the bubble inside the side insets; one wider than the room keeps its leading edge.
    if preview.maxX > maxX { preview.origin.x = maxX - preview.width }
    if preview.minX < minX { preview.origin.x = minX }

    var y = max(preview.minY, top)
    let columnHeight = preview.height + metrics.previewMenuSpacing + menuSize.height
    if y + columnHeight > bottom { y = bottom - columnHeight }
    y = max(y, top)
    preview.origin.y = y
    preview = grid.round(preview)

    func alignedX(width: CGFloat) -> CGFloat {
      let x = input.alignment == .left ? preview.minX : preview.maxX - width
      return min(max(x, minX), maxX - width)
    }

    let menu = grid.round(CGRect(
      x: alignedX(width: menuSize.width),
      y: preview.maxY + metrics.previewMenuSpacing,
      width: menuSize.width,
      height: menuSize.height
    ))
    let accessory = accessorySize.map { size in
      grid.round(CGRect(
        x: alignedX(width: size.width),
        y: preview.minY - metrics.accessoryPreviewSpacing - size.height,
        width: size.width,
        height: size.height
      ))
    }

    let columnBottom = menu.maxY + metrics.bottomInset + safe.bottom
    // Rounding alone never makes a fitting column scroll.
    let isScrollable = columnBottom > viewport.height + 0.5
    let contentHeight = isScrollable ? grid.ceil(columnBottom) : viewport.height
    return Result(
      contentSize: CGSize(width: viewport.width, height: contentHeight),
      contentOffsetY: contentHeight - viewport.height,
      preview: preview,
      menu: menu,
      accessory: accessory,
      menuAnchor: CGPoint(x: input.alignment == .left ? 0 : 1, y: 0),
      isScrollable: isScrollable
    )
  }
}

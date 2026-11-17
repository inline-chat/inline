import AppKit
import InlineKit
import InlineMessageLayout

/// An album's grid on the Mac: one photo or video tile per item, placed by `AlbumMosaic` in
/// Telegram's arrangement. The message view lays the album out as one photo the size of the
/// grid and puts this view in that photo's place; each tile is the item's own media view, so
/// loading, Quick Look, video playback and upload progress work per item.
final class MessageAlbumGridView: NSView {
  /// The grid for `album`, at most `availableWidth` wide (the widest single photo).
  static func mosaic(for album: MessageAlbum, availableWidth: CGFloat) -> AlbumMosaic {
    let width = max(1, availableWidth)
    return AlbumMosaic.layout(
      style: .telegram,
      aspectRatios: album.items.map(aspectRatio),
      // About Telegram's 300 × 380 box, scaled to the width.
      metrics: .init(width: width, maxHeight: width * 380 / 300, spacing: 2),
      grid: PixelGrid(scale: NSScreen.main?.backingScaleFactor ?? 2)
    )
  }

  /// Width over height of an item's media; square when unknown.
  static func aspectRatio(_ item: FullMessage) -> CGFloat {
    let size: (Int?, Int?) = if let photo = item.photoInfo?.bestPhotoSize() {
      (photo.width, photo.height)
    } else if let video = item.videoInfo?.video {
      (video.width, video.height)
    } else {
      (nil, nil)
    }
    guard let width = size.0, let height = size.1, width > 0, height > 0 else { return 1 }
    return CGFloat(width) / CGFloat(height)
  }

  private enum Tile {
    case photo(NewPhotoView)
    case video(NewVideoView)

    var view: NSView {
      switch self {
        case let .photo(view): view
        case let .video(view): view
      }
    }
  }

  private var tiles: [Int64: Tile] = [:]
  private var frames: [Int64: CGRect] = [:]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Tiles are placed top-down, as the mosaic reads.
  override var isFlipped: Bool { true }

  /// `roundsTop` / `roundsBottom`: whether the grid meets the bubble's top and bottom edges
  /// (nothing above it, no caption under it), so it takes the bubble's corners there.
  /// `availableWidth` is the width the size calculator laid the album out at, so the tiles fill
  /// exactly the slot it measured.
  func configure(
    album: MessageAlbum,
    availableWidth: CGFloat,
    scrollState: MessageListScrollState,
    isRightToLeft: Bool,
    roundsTop: Bool,
    roundsBottom: Bool
  ) {
    let mosaic = Self.mosaic(for: album, availableWidth: availableWidth)
    let ids = Set(album.items.map(\.id))
    for (id, tile) in tiles where !ids.contains(id) {
      tile.view.removeFromSuperview()
      tiles[id] = nil
      frames[id] = nil
    }
    for (index, item) in album.items.enumerated() where index < mosaic.tiles.count {
      var frame = mosaic.tiles[index].frame
      if isRightToLeft {
        frame.origin.x = mosaic.size.width - frame.maxX
      }
      frames[item.id] = frame
      switch tile(for: item, scrollState: scrollState) {
        case let .photo(view): view.update(with: item)
        case let .video(view): view.update(with: item)
      }
    }

    let radius = max(0, Theme.messageBubbleCornerRadius - 1)
    var corners: CACornerMask = []
    // A flipped view's layer is geometry-flipped: min Y is the top there.
    let flipped = layer?.contentsAreFlipped() ?? isFlipped
    let top: CACornerMask = flipped ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    let bottom: CACornerMask = flipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    if roundsTop { corners.formUnion(top) }
    if roundsBottom { corners.formUnion(bottom) }
    layer?.cornerRadius = corners.isEmpty ? 0 : radius
    layer?.maskedCorners = corners
    needsLayout = true
  }

  override func layout() {
    super.layout()
    for (id, tile) in tiles {
      if let frame = frames[id] { tile.view.frame = frame }
    }
  }

  func setIsScrolling(_ isScrolling: Bool) {
    for tile in tiles.values {
      if case let .photo(view) = tile { view.setIsScrolling(isScrolling) }
    }
  }

  private func tile(for item: FullMessage, scrollState: MessageListScrollState) -> Tile {
    let isVideo = item.videoInfo != nil
    if let existing = tiles[item.id] {
      switch existing {
        case .photo where !isVideo, .video where isVideo: return existing
        default: existing.view.removeFromSuperview()
      }
    }
    let tile: Tile
    if isVideo {
      let view = NewVideoView(item, scrollState: scrollState)
      // Square tiles; the grid rounds the album's outer corners.
      view.cornerRadiusReduction = .greatestFiniteMagnitude
      tile = .video(view)
    } else {
      let view = NewPhotoView(item, scrollState: scrollState)
      view.cornerRadiusReduction = .greatestFiniteMagnitude
      tile = .photo(view)
    }
    tile.view.translatesAutoresizingMaskIntoConstraints = true
    addSubview(tile.view)
    tiles[item.id] = tile
    return tile
  }
}

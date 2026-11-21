import InlineKit
import InlineMessageLayout
import UIKit

/// An album's tiles: one per photo or video (`MessageAlbum.mediaItems`; its files are rows
/// under the grid, `MessageAlbumFilesView`), placed by `AlbumMosaic` in the chosen
/// `AlbumLayoutStyle`. Each tile is the item's own media view, so loading, video playback,
/// upload progress and the gallery work per item exactly as for a single photo or video.
/// Grid-shaped styles leave rounding to the host; stacks, strips and cards round each tile.
final class MessageAlbumView: UIView, UIScrollViewDelegate {
  /// The widest an album gets, as wide as the widest single photo.
  static let maximumWidth: CGFloat = NewPhotoView.maximumWidth
  /// The tallest an album gets.
  static let maximumHeight: CGFloat = NewPhotoView.maximumHeight

  /// Experimental: how albums are drawn (Settings › Experimental › Album Layout). Read when a
  /// row is planned, so a change shows in chats opened after it.
  static let layoutStyleKey = "experimental.albumLayout"
  static var layoutStyle: AlbumLayoutStyle {
    UserDefaults.standard.string(forKey: layoutStyleKey).flatMap(AlbumLayoutStyle.init(rawValue:)) ?? .telegram
  }

  /// The tiles for `album`, at most `maximumWidth` wide and never wider than `availableWidth`.
  /// `mediaInset` is the bubble-coloured frame around grid-shaped albums (styles whose tiles
  /// round themselves float without one).
  static func mosaic(for album: MessageAlbum, availableWidth: CGFloat, mediaInset: CGFloat = 0, scale: CGFloat) -> AlbumMosaic {
    let style = layoutStyle
    let framed = style != .stack && style != .strip && style != .cards
    let width = min(maximumWidth, availableWidth - (framed ? 2 * mediaInset : 0))
    // Telegram-style albums fill a 280 × 355 box (about Telegram's 300 × 380), scaled to the width.
    let maxHeight = style == .telegram ? width * 380 / 300 : maximumHeight
    let grid = PixelGrid(scale: scale)
    let mosaic = AlbumMosaic.layout(
      style: style,
      aspectRatios: album.mediaItems.map(aspectRatio),
      metrics: .init(width: width, maxHeight: maxHeight, spacing: 2, minRowHeight: 56, maxRowHeight: width * 0.8),
      grid: grid
    )
    guard album.hasFiles else { return mosaic }
    // A lone photo over files is at least as wide as the files' rows ask, in the bubble's padding.
    let filesWidth = MessageAlbumFilesView.preferredWidth(for: album.fileItems)
      + MessageLayoutMetrics().bubbleInsets.horizontal - (framed ? 2 * mediaInset : 0)
    return mosaic.widened(toAtLeast: min(width, filesWidth), grid: grid)
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

    var view: UIView {
      switch self {
        case let .photo(view): view
        case let .video(view): view
      }
    }

    var message: FullMessage {
      switch self {
        case let .photo(view): view.fullMessage
        case let .video(view): view.fullMessage
      }
    }
  }

  private var tiles: [Int64: Tile] = [:]
  private var tileConstraints: [Int64: [NSLayoutConstraint]] = [:]
  /// Holds the tiles of an album that scrolls sideways (strips, cards).
  private var scrollView: UIScrollView?
  private var scrollContent: UIView?
  private var pageWidth: CGFloat?
  private var countLabel: PaddedLabel?

  var onPhotoTap: ((FullMessage, UIView, UIImage?, URL) -> Void)?

  /// The item a point in this view falls on, for menus and replies aimed at one photo. The
  /// front of a stack wins over the cards behind it.
  func item(at point: CGPoint) -> FullMessage? {
    for id in hitOrder {
      guard let tile = tiles[id], !tile.view.isHidden else { continue }
      if tile.view.point(inside: convert(point, to: tile.view), with: nil) { return tile.message }
    }
    return nil
  }

  /// Topmost first.
  private var hitOrder: [Int64] {
    let host = scrollContent ?? self
    return host.subviews.reversed().compactMap { view in tiles.first { $0.value.view === view }?.key }
  }

  /// The tile showing `messageId`, for zoom transitions and highlights.
  func tileView(messageId: Int64) -> UIView? {
    tiles.values.first { $0.message.message.messageId == messageId }?.view
  }

  func configure(album: MessageAlbum, mosaic: AlbumMosaic, isRightToLeft: Bool) {
    let host = tileHost(for: mosaic)
    let items = album.mediaItems
    let ids = Set(items.map(\.id))
    for (id, tile) in tiles where !ids.contains(id) || tile.view.superview !== host {
      tile.view.removeFromSuperview()
      tiles[id] = nil
      tileConstraints[id] = nil
    }
    let content = mosaic.contentSize ?? mosaic.size
    for (index, item) in items.enumerated() where index < mosaic.tiles.count {
      let planned = mosaic.tiles[index]
      var frame = planned.frame
      if isRightToLeft {
        frame.origin.x = content.width - frame.maxX
      }
      let tile = tile(for: item, in: host)
      place(tile.view, id: item.id, frame: frame, in: host)
      tile.view.isHidden = planned.isHidden
      tile.view.transform = planned.rotation == 0 ? .identity : CGAffineTransform(rotationAngle: planned.rotation)
      tile.view.layer.allowsEdgeAntialiasing = planned.rotation != 0
      switch tile {
        case let .photo(view):
          view.plannedSize = frame.size
          view.albumTileCornerRadius = mosaic.tileCornerRadius
          view.update(with: item)
        case let .video(view):
          view.plannedSize = frame.size
          view.albumTileCornerRadius = mosaic.tileCornerRadius
          view.update(with: item)
      }
    }
    // Draw order: a stack's first card in front; otherwise in order.
    let ordered = items.compactMap { tiles[$0.id]?.view }
    for view in mosaic.drawsFirstOnTop ? ordered.reversed() : ordered {
      host.bringSubviewToFront(view)
    }
    updateCount(mosaic: mosaic, album: album)
  }

  // MARK: - Hosts

  /// The view the tiles live in: this view, or a sideways scroller's content.
  private func tileHost(for mosaic: AlbumMosaic) -> UIView {
    let content = mosaic.contentSize ?? mosaic.size
    switch mosaic.scrolling {
      case .none:
        scrollView?.removeFromSuperview()
        scrollView = nil
        scrollContent = nil
        pageWidth = nil
        clipsToBounds = false
        return self
      case .free, .paging:
        let scroll = scrollView ?? makeScrollView()
        scroll.frame = bounds
        scrollContent?.frame = CGRect(origin: .zero, size: content)
        scroll.contentSize = content
        if case let .paging(width) = mosaic.scrolling {
          pageWidth = width
          scroll.decelerationRate = .fast
        } else {
          pageWidth = nil
          scroll.decelerationRate = .normal
        }
        return scrollContent!
    }
  }

  private func makeScrollView() -> UIScrollView {
    let scroll = UIScrollView(frame: bounds)
    scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.alwaysBounceHorizontal = true
    scroll.clipsToBounds = true
    scroll.delegate = self
    let content = UIView()
    scroll.addSubview(content)
    addSubview(scroll)
    scrollView = scroll
    scrollContent = content
    return scroll
  }

  /// Cards stop one at a time, wherever the finger let go.
  func scrollViewWillEndDragging(
    _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
  ) {
    guard let pageWidth, pageWidth > 0 else { return }
    let current = (scrollView.contentOffset.x / pageWidth).rounded()
    let step: CGFloat = velocity.x > 0.2 ? 1 : velocity.x < -0.2 ? -1 : 0
    let projected = velocity.x == 0 ? (targetContentOffset.pointee.x / pageWidth).rounded() : current + step
    let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
    targetContentOffset.pointee.x = min(max(0, projected * pageWidth), maxOffset)
  }

  // MARK: - Tiles

  private func tile(for item: FullMessage, in host: UIView) -> Tile {
    let isVideo = item.videoInfo != nil
    if let existing = tiles[item.id] {
      switch existing {
        case .photo where !isVideo, .video where isVideo: return existing
        default:
          existing.view.removeFromSuperview()
          tileConstraints[item.id] = nil
      }
    }
    let tile: Tile
    if isVideo {
      let view = NewVideoView(item)
      view.isAlbumTile = true
      tile = .video(view)
    } else {
      let view = NewPhotoView(item)
      view.isAlbumTile = true
      view.onTap = { [weak self] message, sourceView, image, url in
        self?.onPhotoTap?(message, sourceView, image, url)
      }
      tile = .photo(view)
    }
    tile.view.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(tile.view)
    tiles[item.id] = tile
    return tile
  }

  /// Media views size themselves from `plannedSize`; the host pins their origin.
  private func place(_ view: UIView, id: Int64, frame: CGRect, in host: UIView) {
    if let constraints = tileConstraints[id], constraints.count == 2 {
      constraints[0].constant = frame.minY
      constraints[1].constant = frame.minX
      return
    }
    let constraints = [
      view.topAnchor.constraint(equalTo: host.topAnchor, constant: frame.minY),
      view.leftAnchor.constraint(equalTo: host.leftAnchor, constant: frame.minX),
    ]
    NSLayoutConstraint.activate(constraints)
    tileConstraints[id] = constraints
  }

  // MARK: - Count

  /// A stack shows how many items it holds, over the front card's corner.
  private func updateCount(mosaic: AlbumMosaic, album: MessageAlbum) {
    guard mosaic.showsCount, let front = mosaic.tiles.first else {
      countLabel?.isHidden = true
      return
    }
    let label = countLabel ?? {
      let label = PaddedLabel()
      label.font = .systemFont(ofSize: 12, weight: .semibold)
      label.textColor = .white
      label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
      label.layer.cornerRadius = 10
      label.layer.masksToBounds = true
      addSubview(label)
      countLabel = label
      return label
    }()
    let items = album.mediaItems
    let videos = items.filter { $0.videoInfo != nil }.count
    let noun = videos == 0 ? "photos" : videos == items.count ? "videos" : "items"
    label.text = "\(items.count) \(noun)"
    label.isHidden = false
    let size = label.intrinsicContentSize
    label.frame = CGRect(x: front.frame.maxX - size.width - 8, y: front.frame.minY + 8, width: size.width, height: 20)
    bringSubviewToFront(label)
  }
}

/// A label with horizontal padding, for small pills.
private final class PaddedLabel: UILabel {
  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + 16, height: max(size.height, 20))
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.insetBy(dx: 8, dy: 0))
  }
}

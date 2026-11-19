import AppKit
import InlineKit
import Logger
import SwiftUI

// The chat info media grid: month blocks of square thumbnails with 2pt gaps and rounded
// outer corners. Rows are lazy SwiftUI rows of fixed-size AppKit cells; each cell is a few
// layers, never a message photo or video view.

enum ChatInfoMediaGridMetrics {
  static let spacing: CGFloat = 2
  static let cornerRadius: CGFloat = 10
  static let minimumSide: CGFloat = 128
  static let maximumColumns = 6
  static let minimumColumns = 3
  /// The column width assumed before the first measurement, so the first frame is right.
  static let defaultWidth: CGFloat = 640
  /// Rows ahead of the end at which the next page is requested.
  static let prefetchRows = 6

  /// The most columns that keep cells at least `minimumSide`: 4 at 640pt, 3 below ~520pt.
  static func columns(for width: CGFloat) -> Int {
    var columns = maximumColumns
    while columns > minimumColumns, side(for: width, columns: columns) < minimumSide {
      columns -= 1
    }
    return columns
  }

  static func side(for width: CGFloat, columns: Int) -> CGFloat {
    max(1, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
  }
}

/// Outer corners of a month block that a cell sits on.
struct ChatInfoGridCorners: OptionSet, Equatable {
  let rawValue: UInt8
  static let topLeading = Self(rawValue: 1 << 0)
  static let topTrailing = Self(rawValue: 1 << 1)
  static let bottomLeading = Self(rawValue: 1 << 2)
  static let bottomTrailing = Self(rawValue: 1 << 3)

  /// Corners for item `index` of a block of `count` items in `columns` columns. A short last
  /// row also rounds the cell above its gap, so the block keeps a rounded outline.
  static func forItem(_ index: Int, count: Int, columns: Int) -> Self {
    let rows = (count + columns - 1) / columns
    let row = index / columns
    let column = index % columns
    let lastRowCount = count - (rows - 1) * columns
    var corners: Self = []
    if row == 0, column == 0 { corners.insert(.topLeading) }
    if row == 0, column == columns - 1 || index == count - 1 { corners.insert(.topTrailing) }
    if row == rows - 1, column == 0 { corners.insert(.bottomLeading) }
    if row == rows - 1, index == count - 1 { corners.insert(.bottomTrailing) }
    if rows > 1, lastRowCount < columns, row == rows - 2, column == columns - 1 { corners.insert(.bottomTrailing) }
    return corners
  }
}

struct ChatInfoMediaCellModel: Equatable {
  let media: MediaMessage
  let thumbnail: ChatInfoThumbnailSource?
  let corners: ChatInfoGridCorners

  init(media: MediaMessage, corners: ChatInfoGridCorners) {
    self.media = media
    self.corners = corners
    thumbnail = ChatInfoThumbnailSource(media.photo ?? media.video?.thumbnail)
  }

  var isVideo: Bool { media.video != nil }

  var badge: String? {
    guard let video = media.video?.video else { return nil }
    if video.isAnimated { return "GIF" }
    guard let duration = video.duration, duration > 0 else { return nil }
    return ChatInfoResourceFormat.duration(duration)
  }
}

/// Places one grid row's cells on whole points, so gaps and edges stay crisp.
struct ChatInfoMediaRowLayout: Layout {
  let columns: Int
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = Self.resolvedWidth(proposal.width)
    return CGSize(width: width, height: ChatInfoMediaGridMetrics.side(for: width, columns: columns).rounded())
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let height = ChatInfoMediaGridMetrics.side(for: bounds.width, columns: columns).rounded()
    let stride = (bounds.width + spacing) / CGFloat(columns)
    for (index, subview) in subviews.enumerated() {
      let minX = (CGFloat(index) * stride).rounded()
      let maxX = (CGFloat(index + 1) * stride).rounded() - spacing
      subview.place(
        at: CGPoint(x: bounds.minX + minX, y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: max(1, maxX - minX), height: height)
      )
    }
  }

  private static func resolvedWidth(_ width: CGFloat?) -> CGFloat {
    guard let width, width.isFinite, width > 0 else { return ChatInfoMediaGridMetrics.defaultWidth }
    return width
  }
}

/// One row of the grid. Its cells drop their images while the row is offscreen.
struct ChatInfoMediaGridRow: View {
  let models: [ChatInfoMediaCellModel]
  let columns: Int
  let side: CGFloat
  let controller: ChatInfoMediaGridController

  @State private var isOnScreen = true

  var body: some View {
    ChatInfoMediaRowLayout(columns: columns, spacing: ChatInfoMediaGridMetrics.spacing) {
      ForEach(models, id: \.media.id) { model in
        ChatInfoMediaCell(model: model, side: side, isActive: isOnScreen, controller: controller)
      }
    }
    .onAppear { isOnScreen = true }
    .onDisappear { isOnScreen = false }
  }
}

struct ChatInfoMediaCell: NSViewRepresentable {
  let model: ChatInfoMediaCellModel
  let side: CGFloat
  let isActive: Bool
  let controller: ChatInfoMediaGridController

  func makeNSView(context: Context) -> ChatInfoMediaCellView {
    let view = ChatInfoMediaCellView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    view.controller = controller
    view.configure(model, side: side)
    return view
  }

  func updateNSView(_ view: ChatInfoMediaCellView, context: Context) {
    view.controller = controller
    view.isActive = isActive
    view.configure(model, side: side)
  }

  static func dismantleNSView(_ view: ChatInfoMediaCellView, coordinator: ()) {
    view.prepareForRemoval()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatInfoMediaCellView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? side, height: proposal.height ?? side)
  }
}

// MARK: - Cell view

/// A square thumbnail with a duration badge, click to preview, drag out, and a context menu.
final class ChatInfoMediaCellView: ChatInfoThumbnailLayerView, NSDraggingSource {
  private static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
  private static let dragThreshold: CGFloat = 4

  weak var controller: ChatInfoMediaGridController?
  private(set) var model: ChatInfoMediaCellModel?
  private var side: CGFloat = 0

  private var badgeBackground: CALayer?
  private var badgeText: CATextLayer?
  private var badgeSize: CGSize = .zero
  private var transferBackground: CALayer?
  private var transferRing: CAShapeLayer?
  private var mouseDownPoint: NSPoint?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ model: ChatInfoMediaCellModel, side: CGFloat) {
    guard model != self.model || side != self.side else { return }
    let previousID = self.model?.media.id
    self.model = model
    self.side = side
    if previousID != model.media.id {
      if let previousID { controller?.unregister(self, id: previousID) }
      controller?.register(self, id: model.media.id)
      setTransferProgress(controller?.transferProgress(for: model.media.id))
    }
    setThumbnail(model.thumbnail, pointSide: side, message: model.media.message)
    updateBadge(model.badge)
    needsLayout = true
  }

  func prepareForRemoval() {
    if let id = model?.media.id { controller?.unregister(self, id: id) }
    isActive = false
  }

  // MARK: Layout

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyCorners()
    if let badgeBackground, let badgeText {
      let inset: CGFloat = 5
      let frame = CGRect(
        x: bounds.maxX - inset - badgeSize.width,
        y: bounds.maxY - inset - badgeSize.height,
        width: badgeSize.width,
        height: badgeSize.height
      )
      badgeBackground.frame = frame
      badgeBackground.cornerRadius = frame.height / 2
      let textHeight = ceil(Self.badgeFont.ascender - Self.badgeFont.descender)
      badgeText.frame = frame.insetBy(dx: 6, dy: (frame.height - textHeight) / 2)
    }
    if let transferBackground, let transferRing {
      let diameter: CGFloat = 36
      let frame = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
      transferBackground.frame = frame
      transferBackground.cornerRadius = diameter / 2
      transferRing.frame = frame
      transferRing.path = CGPath(ellipseIn: CGRect(x: 6, y: 6, width: diameter - 12, height: diameter - 12), transform: nil)
    }
    CATransaction.commit()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    badgeText?.contentsScale = window?.backingScaleFactor ?? 2
  }

  private func applyCorners() {
    guard let layer, let corners = model?.corners else { return }
    // A flipped view's layer has its minimum Y at the top.
    let flipped = layer.contentsAreFlipped()
    let top: (CACornerMask, CACornerMask) = flipped
      ? (.layerMinXMinYCorner, .layerMaxXMinYCorner) : (.layerMinXMaxYCorner, .layerMaxXMaxYCorner)
    let bottom: (CACornerMask, CACornerMask) = flipped
      ? (.layerMinXMaxYCorner, .layerMaxXMaxYCorner) : (.layerMinXMinYCorner, .layerMaxXMinYCorner)
    var mask: CACornerMask = []
    if corners.contains(.topLeading) { mask.insert(top.0) }
    if corners.contains(.topTrailing) { mask.insert(top.1) }
    if corners.contains(.bottomLeading) { mask.insert(bottom.0) }
    if corners.contains(.bottomTrailing) { mask.insert(bottom.1) }
    layer.maskedCorners = mask
    layer.cornerRadius = mask.isEmpty ? 0 : ChatInfoMediaGridMetrics.cornerRadius
    layer.cornerCurve = .continuous
  }

  private func updateBadge(_ text: String?) {
    guard let text else {
      badgeBackground?.removeFromSuperlayer()
      badgeText?.removeFromSuperlayer()
      badgeBackground = nil
      badgeText = nil
      return
    }
    if badgeBackground == nil {
      let background = CALayer()
      background.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
      background.actions = ["position": NSNull(), "bounds": NSNull()]
      let label = CATextLayer()
      label.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
      label.alignmentMode = .center
      label.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
      layer?.addSublayer(background)
      layer?.addSublayer(label)
      badgeBackground = background
      badgeText = label
    }
    let string = NSAttributedString(string: text, attributes: [
      .font: Self.badgeFont,
      .foregroundColor: NSColor.white,
    ])
    badgeText?.string = string
    let size = string.size()
    badgeSize = CGSize(width: ceil(size.width) + 12, height: 18)
  }

  /// Shows a ring while the video downloads for preview; nil hides it.
  func setTransferProgress(_ progress: Double?) {
    guard let progress else {
      transferBackground?.removeFromSuperlayer()
      transferRing?.removeFromSuperlayer()
      transferBackground = nil
      transferRing = nil
      return
    }
    if transferRing == nil {
      let background = CALayer()
      background.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
      let ring = CAShapeLayer()
      ring.fillColor = nil
      ring.strokeColor = NSColor.white.cgColor
      ring.lineWidth = 2
      ring.lineCap = .round
      layer?.addSublayer(background)
      layer?.addSublayer(ring)
      transferBackground = background
      transferRing = ring
      needsLayout = true
    }
    transferRing?.strokeEnd = max(0.05, min(progress, 1))
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    mouseDownPoint = convert(event.locationInWindow, from: nil)
    imageLayer.opacity = 0.82
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownPoint else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
    mouseDownPoint = nil
    imageLayer.opacity = 1
    guard let model, let url = ChatInfoResourceFiles.recordedURL(for: model.media) else { return }
    let item = NSDraggingItem(pasteboardWriter: url as NSURL)
    let preview = displayedImage.map { NSImage(cgImage: $0, size: bounds.size) }
    item.setDraggingFrame(bounds, contents: preview)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  override func mouseUp(with event: NSEvent) {
    imageLayer.opacity = 1
    defer { mouseDownPoint = nil }
    guard mouseDownPoint != nil, let model else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point) else { return }
    controller?.activate(model.media)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let model else { return nil }
    return controller?.menu(for: model.media, in: self)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    .copy
  }

  // MARK: Accessibility

  override func accessibilityLabel() -> String? {
    guard let model else { return nil }
    let kind = model.isVideo ? String(localized: "Video") : String(localized: "Photo")
    let date = ChatInfoResourceFormat.longDateFormatter.string(from: model.media.message.date)
    if let badge = model.badge {
      return "\(kind), \(badge), \(date)"
    }
    return "\(kind), \(date)"
  }

  override func accessibilityPerformPress() -> Bool {
    guard let model else { return false }
    controller?.activate(model.media)
    return true
  }

  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    guard let model else { return nil }
    return [
      NSAccessibilityCustomAction(name: String(localized: "Show in Chat")) { [weak self] in
        self?.controller?.onShowInChat(model.media.message)
        return true
      },
    ]
  }
}

// MARK: - Controller

/// Actions for one media grid: preview, downloads, menus. Cells register by message ID so
/// Quick Look can zoom from the right cell and download progress reaches it.
@MainActor
final class ChatInfoMediaGridController {
  private struct WeakCell {
    weak var view: ChatInfoMediaCellView?
  }

  private(set) var mediaMessages: [MediaMessage] = []
  var onShowInChat: (Message) -> Void = { _ in }

  private var cells: [Int64: WeakCell] = [:]
  private var transfers: [Int64: Double] = [:]
  private var openGeneration = 0

  func update(mediaMessages: [MediaMessage], onShowInChat: @escaping (Message) -> Void) {
    self.mediaMessages = mediaMessages
    self.onShowInChat = onShowInChat
  }

  func register(_ cell: ChatInfoMediaCellView, id: Int64) {
    cells[id] = WeakCell(view: cell)
  }

  func unregister(_ cell: ChatInfoMediaCellView, id: Int64) {
    if cells[id]?.view === cell { cells[id] = nil }
  }

  func cell(for id: Int64) -> ChatInfoMediaCellView? {
    cells[id]?.view
  }

  func transferProgress(for id: Int64) -> Double? {
    transfers[id]
  }

  /// A click previews the item; clicking a video that is downloading cancels it.
  func activate(_ media: MediaMessage) {
    if let video = media.video, transfers[media.id] != nil {
      FileDownloader.shared.cancelVideoDownload(videoId: video.id)
      setTransfer(nil, for: media.id)
      return
    }
    openGeneration += 1
    let generation = openGeneration
    Task { @MainActor [weak self] in
      guard let self, let url = await localFile(for: media), generation == openGeneration else { return }
      presentPreview(selecting: media, resolvedURL: url)
    }
  }

  func menu(for media: MediaMessage, in cell: ChatInfoMediaCellView) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(ChatInfoMenuAction.item(String(localized: "Quick Look"), symbol: "eye") { [weak self] in
      self?.activate(media)
    })
    menu.addItem(ChatInfoMenuAction.item(String(localized: "Show in Chat"), symbol: "text.bubble") { [weak self] in
      self?.onShowInChat(media.message)
    })

    guard let url = ChatInfoResourceFiles.recordedURL(for: media) else { return menu }
    let isPhoto = media.photo != nil
    menu.addItem(.separator())
    menu.addItem(ChatInfoMenuAction.item(
      isPhoto ? String(localized: "Copy Image") : String(localized: "Copy Video"),
      symbol: "doc.on.doc"
    ) {
      if isPhoto {
        ChatInfoResourceFiles.copyImage(url)
      } else {
        ChatInfoResourceFiles.copyFile(url)
      }
    })
    menu.addItem(ChatInfoMenuAction.item(String(localized: "Save As…"), symbol: "square.and.arrow.down") {
      [weak cell] in
      ChatInfoResourceFiles.saveAs(url, suggestedName: Self.fileName(for: media, url: url), window: cell?.window)
    })
    menu.addItem(ChatInfoMenuAction.item(String(localized: "Share…"), symbol: "square.and.arrow.up") {
      [weak cell] in
      guard let cell else { return }
      NSSharingServicePicker(items: [url as NSURL]).show(relativeTo: cell.bounds, of: cell, preferredEdge: .minY)
    })
    return menu
  }

  // MARK: Private

  private func localFile(for media: MediaMessage) async -> URL? {
    if let photo = media.photo {
      let url = await ChatInfoResourceFiles.ensurePhoto(photo, message: media.message)
      if url == nil { ToastCenter.shared.showError("Couldn’t load this photo") }
      return url
    }
    guard let video = media.video else { return nil }
    do {
      let url = try await ChatInfoResourceFiles.ensureVideo(video, message: media.message) { [weak self] progress in
        // A late progress event must not bring back a ring the user cancelled.
        guard let self, progress == 0 || transfers[media.id] != nil else { return }
        setTransfer(progress, for: media.id)
      }
      setTransfer(nil, for: media.id)
      return url
    } catch {
      let wasCancelled = transfers[media.id] == nil
      setTransfer(nil, for: media.id)
      if !wasCancelled, !FileDownloader.isCancellation(error) {
        Log.shared.error("Failed to download video for preview", error: error)
        ToastCenter.shared.showError("Couldn’t download this video")
      }
      return nil
    }
  }

  private func setTransfer(_ progress: Double?, for id: Int64) {
    transfers[id] = progress
    cell(for: id)?.setTransferProgress(progress)
  }

  private func presentPreview(selecting media: MediaMessage, resolvedURL: URL) {
    let directories = ChatInfoResourceFiles.Directories()
    var items: [ChatInfoResourcePreview.Item] = []
    items.reserveCapacity(mediaMessages.count)
    for row in mediaMessages {
      let url = row.id == media.id ? resolvedURL : directories.recordedURL(for: row)
      guard let url else { continue }
      items.append(ChatInfoResourcePreview.Item(id: row.id, url: url, title: Self.title(for: row)))
    }
    if !items.contains(where: { $0.id == media.id }) {
      items = [ChatInfoResourcePreview.Item(id: media.id, url: resolvedURL, title: Self.title(for: media))]
    }
    ChatInfoResourcePreview.shared.present(items, selecting: media.id) { [weak self] id in
      self?.cell(for: id)
    }
  }

  private static func title(for media: MediaMessage) -> String {
    let kind = media.video != nil ? String(localized: "Video") : String(localized: "Photo")
    return "\(kind) · \(ChatInfoResourceFormat.longDateFormatter.string(from: media.message.date))"
  }

  /// Matches the file browser's names: "Image 123.jpg", "Video 123.mp4".
  private static func fileName(for media: MediaMessage, url: URL) -> String {
    let ext = url.pathExtension.isEmpty ? (media.video != nil ? "mp4" : "jpg") : url.pathExtension
    let stem = media.video != nil ? "Video" : "Image"
    return "\(stem) \(media.message.messageId).\(ext)"
  }
}

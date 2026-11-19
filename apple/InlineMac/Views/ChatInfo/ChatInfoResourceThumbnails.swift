import AppKit
import ImageIO
import InlineKit
import InlineUI
import SwiftUI

// Thumbnails for the chat info media grid, file icons and link previews.
//
// Cells ask the loader for a thumbnail at their pixel size. A memory hit is applied in
// the same pass, so cached media renders on the first frame. Misses decode off the main
// thread with ImageIO at the requested size, never at the photo's full resolution, and
// download the photo first when no local file exists. The cache is separate from the
// chat's `ImageCacheManager` so browsing chat info never evicts message images.

/// A stored photo to show as a thumbnail.
struct ChatInfoThumbnailSource: Equatable {
  let photo: PhotoInfo
  /// Identifies the photo across local path changes: a download keeps its cached thumbnail.
  let key: String
  /// The stripped preview bytes, shown blurred until the thumbnail decodes.
  let strippedBytes: Data?

  init?(_ photo: PhotoInfo?) {
    guard let photo, photo.bestPhotoSize() != nil else { return nil }
    self.photo = photo
    key = "p\(photo.photo.photoId)"
    strippedBytes = InlineTinyThumbnailDecoder.strippedBytes(from: photo)
  }

  /// A stored regular size has a file on disk (by its recorded path, without touching disk).
  var hasRecordedLocalFile: Bool {
    photo.sizes.contains { $0.type != "s" && $0.localPath?.isEmpty == false }
  }

  /// The recorded local file of the largest regular size, built without disk access.
  func recordedLocalURL(directory: URL) -> URL? {
    guard let localPath = photo.localPhotoSizeCandidates().first?.localPath else { return nil }
    return directory.appendingPathComponent(localPath)
  }
}

@MainActor
final class ChatInfoThumbnailLoader {
  static let shared = ChatInfoThumbnailLoader()

  typealias Completion = @MainActor (CGImage?) -> Void

  struct Ticket: Equatable {
    fileprivate let key: String
    fileprivate let id: UInt64
  }

  private final class Request {
    var completions: [UInt64: Completion] = [:]
    var operation: Operation?
    var download: Task<Void, Never>?
  }

  /// Pixel sizes thumbnails are decoded at, so small width changes share cache entries.
  static let pixelBuckets = [64, 96, 128, 192, 256, 320, 384, 512, 640]
  /// Waits this long before downloading, so cells flicked past do not start transfers.
  private static let downloadDelay: Duration = .milliseconds(150)

  private let cache = NSCache<NSString, CGImage>()
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "ChatInfoThumbnailLoader"
    queue.maxConcurrentOperationCount = 3
    queue.qualityOfService = .userInitiated
    return queue
  }()

  private var requests: [String: Request] = [:]
  private var nextID: UInt64 = 0

  private init() {
    cache.countLimit = 800
    cache.totalCostLimit = 96 * 1_024 * 1_024
  }

  static func pixelBucket(points: CGFloat, scale: CGFloat) -> Int {
    let pixels = Int((max(points, 1) * max(scale, 1)).rounded(.up))
    return pixelBuckets.first { $0 >= pixels } ?? pixelBuckets[pixelBuckets.count - 1]
  }

  /// A thumbnail decoded at `bucket` or larger.
  func cachedImage(_ source: ChatInfoThumbnailSource, bucket: Int) -> CGImage? {
    for candidate in Self.pixelBuckets where candidate >= bucket {
      if let image = cache.object(forKey: Self.cacheKey(source.key, bucket: candidate) as NSString) {
        return image
      }
    }
    return nil
  }

  func cachedTinyImage(_ source: ChatInfoThumbnailSource) -> CGImage? {
    cache.object(forKey: Self.tinyKey(source.key) as NSString)
  }

  /// Decodes the thumbnail, downloading the photo first when no local file exists.
  func load(
    _ source: ChatInfoThumbnailSource,
    bucket: Int,
    message: Message?,
    completion: @escaping Completion
  ) -> Ticket {
    let key = Self.cacheKey(source.key, bucket: bucket)
    let (ticket, request, isNew) = enqueue(key: key, completion: completion)
    if isNew {
      startDecode(key: key, request: request, photo: source.photo, fileURL: nil, bucket: bucket, message: message)
    }
    return ticket
  }

  /// Decodes the stripped preview bytes into a small, soft image.
  func loadTiny(_ source: ChatInfoThumbnailSource, completion: @escaping Completion) -> Ticket? {
    guard let bytes = source.strippedBytes else { return nil }
    let key = Self.tinyKey(source.key)
    let (ticket, request, isNew) = enqueue(key: key, completion: completion)
    if isNew {
      let operation = BlockOperation()
      operation.queuePriority = .high
      operation.addExecutionBlock { [weak operation] in
        guard operation?.isCancelled == false else { return }
        let image = Self.decodeTiny(bytes)
        DispatchQueue.main.async {
          MainActor.assumeIsolated { ChatInfoThumbnailLoader.shared.finish(key: key, image: image) }
        }
      }
      request.operation = operation
      queue.addOperation(operation)
    }
    return ticket
  }

  func cancel(_ ticket: Ticket?) {
    guard let ticket, let request = requests[ticket.key] else { return }
    request.completions[ticket.id] = nil
    guard request.completions.isEmpty else { return }
    request.operation?.cancel()
    request.download?.cancel()
    requests[ticket.key] = nil
  }

  // MARK: - Private

  fileprivate static func cacheKey(_ key: String, bucket: Int) -> String {
    "\(key)@\(bucket)"
  }

  private static func tinyKey(_ key: String) -> String {
    "\(key)@tiny"
  }

  private func enqueue(key: String, completion: @escaping Completion) -> (Ticket, Request, Bool) {
    nextID &+= 1
    let ticket = Ticket(key: key, id: nextID)
    if let request = requests[key] {
      request.completions[ticket.id] = completion
      return (ticket, request, false)
    }
    let request = Request()
    request.completions[ticket.id] = completion
    requests[key] = request
    return (ticket, request, true)
  }

  private func startDecode(
    key: String,
    request: Request,
    photo: PhotoInfo,
    fileURL: URL?,
    bucket: Int,
    message: Message?
  ) {
    let operation = BlockOperation()
    operation.addExecutionBlock { [weak operation] in
      guard operation?.isCancelled == false else { return }
      // Existence checks stay here, off the main thread.
      let urls = fileURL.map { [$0] } ?? FileCache.cachedLocalURLCandidates(photo: photo)
      var image: CGImage?
      for url in urls {
        guard operation?.isCancelled == false else { return }
        if let decoded = Self.decode(url: url, bucket: bucket) {
          image = decoded
          break
        }
      }
      let needsDownload = urls.isEmpty && fileURL == nil
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let loader = ChatInfoThumbnailLoader.shared
          if needsDownload {
            loader.startDownload(key: key, photo: photo, bucket: bucket, message: message)
          } else {
            loader.finish(key: key, image: image)
          }
        }
      }
    }
    request.operation = operation
    queue.addOperation(operation)
  }

  private func startDownload(key: String, photo: PhotoInfo, bucket: Int, message: Message?) {
    guard let request = requests[key] else { return }
    request.operation = nil
    request.download = Task { [weak self] in
      try? await Task.sleep(for: Self.downloadDelay)
      guard !Task.isCancelled else { return }
      // FileCache joins a transfer another view already started for the same photo.
      let url = await FileCache.shared.downloadAndWait(photo: photo, reloadMessageOnFinish: message)
      guard let self, !Task.isCancelled, let request = requests[key] else { return }
      request.download = nil
      guard let url else {
        finish(key: key, image: nil)
        return
      }
      startDecode(key: key, request: request, photo: photo, fileURL: url, bucket: bucket, message: message)
    }
  }

  private func finish(key: String, image: CGImage?) {
    if let image {
      cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }
    guard let request = requests.removeValue(forKey: key) else { return }
    for completion in request.completions.values {
      completion(image)
    }
  }

  /// Decodes at the cell's pixel size: the shorter side covers `bucket`, the longer side is
  /// capped so a panorama does not decode at full width.
  nonisolated static func decode(url: URL, bucket: Int) -> CGImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

    var aspect: CGFloat = 1
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
       let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
       width > 0, height > 0
    {
      aspect = max(width, height) / min(width, height)
    }

    let maxPixelSize = Int((CGFloat(bucket) * min(aspect, 3)).rounded(.up))
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
  }

  /// The stripped preview redrawn at a dozen pixels; the layer's linear magnification then
  /// renders it as a soft blur without a blur pass.
  nonisolated static func decodeTiny(_ bytes: Data) -> CGImage? {
    guard let jpeg = InlineTinyThumbnailDecoder.decodeJPEGData(from: bytes),
          let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    let longSide: CGFloat = 12
    let scale = longSide / CGFloat(max(image.width, image.height, 1))
    let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
    let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return image }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
  }
}

/// A layer-backed thumbnail: placeholder fill, blurred stripped preview, then the image.
///
/// Manual layout, no constraints, one image layer. Subclasses add badges and interaction.
class ChatInfoThumbnailLayerView: NSView {
  private static let fadeDuration: CFTimeInterval = 0.18

  let imageLayer = CALayer()

  private(set) var source: ChatInfoThumbnailSource?
  private(set) var displayedImage: CGImage?
  private var isShowingFullImage = false
  private var pointSide: CGFloat = 0
  private var bucket = 0
  private var message: Message?
  private var ticket: ChatInfoThumbnailLoader.Ticket?
  private var tinyTicket: ChatInfoThumbnailLoader.Ticket?

  /// Offscreen cells drop their image so a long scroll doesn't retain every thumbnail.
  var isActive = true {
    didSet {
      guard isActive != oldValue else { return }
      if isActive {
        reload(animated: false)
      } else {
        cancelLoads()
        setImage(nil, isFull: false, animated: false)
      }
    }
  }

  var placeholderColor: NSColor = .tertiarySystemFill {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.masksToBounds = true

    imageLayer.contentsGravity = .resizeAspectFill
    imageLayer.masksToBounds = true
    imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    layer?.addSublayer(imageLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = placeholderColor.cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // SwiftUI removes dismantled cells from the window; drop their pending work.
    if window == nil {
      cancelLoads()
    } else if !isShowingFullImage {
      reload(animated: false)
    }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = bounds
    CATransaction.commit()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let scale = window?.backingScaleFactor ?? 2
    imageLayer.contentsScale = scale
    let newBucket = ChatInfoThumbnailLoader.pixelBucket(points: pointSide, scale: scale)
    if newBucket > bucket {
      bucket = newBucket
      reload(animated: false)
    }
  }

  /// Shows `source` at `pointSide` points. Cached thumbnails apply in this call.
  func setThumbnail(_ source: ChatInfoThumbnailSource?, pointSide: CGFloat, message: Message?) {
    self.message = message
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let newBucket = ChatInfoThumbnailLoader.pixelBucket(points: pointSide, scale: scale)
    let previousKey = self.source?.key
    let previousBucket = bucket
    guard source != self.source || newBucket != previousBucket else { return }

    self.source = source
    self.pointSide = pointSide
    bucket = newBucket

    guard source?.key == previousKey else {
      cancelLoads()
      setImage(nil, isFull: false, animated: false)
      reload(animated: false)
      return
    }
    // The same photo with a newly recorded path or size keeps its image unless it needs a
    // sharper one; the cache key does not depend on the path.
    if isShowingFullImage, newBucket <= previousBucket { return }
    reload(animated: false)
  }

  private func reload(animated: Bool) {
    guard isActive, let source else { return }
    let loader = ChatInfoThumbnailLoader.shared

    if let image = loader.cachedImage(source, bucket: bucket) {
      cancelLoads()
      setImage(image, isFull: true, animated: animated)
      return
    }

    if displayedImage == nil, let tiny = loader.cachedTinyImage(source) {
      setImage(tiny, isFull: false, animated: false)
    } else if displayedImage == nil, tinyTicket == nil {
      tinyTicket = loader.loadTiny(source) { [weak self] image in
        guard let self else { return }
        tinyTicket = nil
        guard let image, !isShowingFullImage, self.source?.key == source.key else { return }
        setImage(image, isFull: false, animated: false)
      }
    }

    let requestedKey = source.key
    if let ticket, ticket.key == ChatInfoThumbnailLoader.cacheKey(requestedKey, bucket: bucket) { return }
    loader.cancel(ticket)
    ticket = loader.load(source, bucket: bucket, message: message) { [weak self] image in
      guard let self else { return }
      ticket = nil
      guard let image, self.source?.key == requestedKey, isActive else { return }
      setImage(image, isFull: true, animated: window != nil)
    }
  }

  private func cancelLoads() {
    ChatInfoThumbnailLoader.shared.cancel(ticket)
    ChatInfoThumbnailLoader.shared.cancel(tinyTicket)
    ticket = nil
    tinyTicket = nil
  }

  private func setImage(_ image: CGImage?, isFull: Bool, animated: Bool) {
    if animated, image != nil {
      let transition = CATransition()
      transition.type = .fade
      transition.duration = Self.fadeDuration
      imageLayer.add(transition, forKey: "contents")
    }
    displayedImage = image
    isShowingFullImage = isFull && image != nil
    // The layer's default linear magnification renders the dozen-pixel preview as a blur.
    imageLayer.contents = image
    imageDidChange()
  }

  /// Subclass hook, for example to drop a placeholder glyph.
  func imageDidChange() {}
}

/// A non-interactive thumbnail for SwiftUI rows: events fall through to the row.
struct ChatInfoResourceThumbnail: NSViewRepresentable {
  let source: ChatInfoThumbnailSource?
  let side: CGFloat
  var cornerRadius: CGFloat = 8
  var message: Message?
  var isActive = true

  func makeNSView(context: Context) -> PassthroughThumbnailView {
    let view = PassthroughThumbnailView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    view.layer?.cornerRadius = cornerRadius
    view.layer?.cornerCurve = .continuous
    view.setThumbnail(source, pointSide: side, message: message)
    return view
  }

  func updateNSView(_ view: PassthroughThumbnailView, context: Context) {
    view.layer?.cornerRadius = cornerRadius
    view.isActive = isActive
    view.setThumbnail(source, pointSide: side, message: message)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassthroughThumbnailView, context: Context) -> CGSize? {
    CGSize(width: side, height: side)
  }

  final class PassthroughThumbnailView: ChatInfoThumbnailLayerView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

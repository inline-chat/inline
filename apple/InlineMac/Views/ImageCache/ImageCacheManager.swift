import AppKit
import Foundation
import ImageIO

final class ImageCacheManager {
  typealias Completion = (NSImage?) -> Void

  static let shared = ImageCacheManager()

  private let memoryCache = NSCache<NSString, NSImage>()
  private let decodeQueue = DispatchQueue(
    label: "ImageCacheManager.decodeQueue",
    qos: .utility,
    autoreleaseFrequency: .workItem
  )
  private let stateQueue = DispatchQueue(label: "ImageCacheManager.stateQueue")
  private var inFlight: [String: [Completion]] = [:]

  private let fileManager = FileManager.default
  private let diskCacheURL: URL

  private init() {
    memoryCache.countLimit = 100
    memoryCache.totalCostLimit = 1_024 * 1_024 * 100

    let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    diskCacheURL = cachesDirectory.appendingPathComponent("ImageCache")
    try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
  }

  func image(
    for url: URL,
    loadSync _: Bool,
    cacheKey: String? = nil,
    targetSize: CGSize? = nil,
    scale: CGFloat = 0,
    completion: @escaping Completion
  ) {
    let keyString = Self.cacheKey(for: url, cacheKey: cacheKey, targetSize: targetSize, scale: scale)
    let nsCacheKey = keyString as NSString

    if let cachedImage = memoryCache.object(forKey: nsCacheKey) {
      completion(cachedImage)
      return
    }

    stateQueue.async { [weak self] in
      guard let self else { return }

      if let cachedImage = memoryCache.object(forKey: nsCacheKey) {
        DispatchQueue.main.async {
          completion(cachedImage)
        }
        return
      }

      if var completions = inFlight[keyString] {
        completions.append(completion)
        inFlight[keyString] = completions
        return
      }

      inFlight[keyString] = [completion]
      decodeQueue.async { [weak self] in
        guard let self else { return }

        if let cachedImage = self.memoryCache.object(forKey: nsCacheKey) {
          self.finish(keyString: keyString, image: cachedImage)
          return
        }

        let image = self.loadPreparedImage(from: url, targetSize: targetSize, scale: scale)
        self.finish(keyString: keyString, image: image)
      }
    }
  }

  func prewarm(
    for url: URL,
    cacheKey: String? = nil,
    targetSize: CGSize? = nil,
    scale: CGFloat = 0
  ) {
    image(for: url, loadSync: false, cacheKey: cacheKey, targetSize: targetSize, scale: scale) { _ in }
  }

  func cachedImage(
    for url: URL,
    cacheKey: String? = nil,
    targetSize: CGSize? = nil,
    scale: CGFloat = 0
  ) -> NSImage? {
    let key = Self.cacheKey(for: url, cacheKey: cacheKey, targetSize: targetSize, scale: scale)
    return memoryCache.object(forKey: key as NSString)
  }

  func cachedImage(cacheKey: String) -> NSImage? {
    memoryCache.object(forKey: cacheKey as NSString)
  }

  static func cacheKey(
    for url: URL,
    cacheKey: String? = nil,
    targetSize: CGSize? = nil,
    scale: CGFloat = 0
  ) -> String {
    let base = cacheKey ?? url.absoluteString
    guard let targetSize else { return base }

    let resolvedScale = resolvedScale(scale)
    let width = max(Int((targetSize.width * resolvedScale).rounded(.up)), 1)
    let height = max(Int((targetSize.height * resolvedScale).rounded(.up)), 1)
    return "\(base)#prepared:\(width)x\(height)"
  }

  private func finish(keyString: String, image: NSImage?) {
    if let image {
      memoryCache.setObject(image, forKey: keyString as NSString, cost: Self.cost(of: image))
    }

    stateQueue.async { [weak self] in
      guard let self else { return }
      let completions = inFlight.removeValue(forKey: keyString) ?? []
      DispatchQueue.main.async {
        completions.forEach { $0(image) }
      }
    }
  }

  private func loadPreparedImage(from url: URL, targetSize: CGSize?, scale: CGFloat) -> NSImage? {
    guard let targetSize else {
      return NSImage(contentsOf: url)
    }

    let resolvedScale = Self.resolvedScale(scale)
    let maxPixelSize = max(
      Int((max(targetSize.width, targetSize.height) * resolvedScale).rounded(.up)),
      1
    )

    let sourceOptions = [
      kCGImageSourceShouldCache: false,
    ] as CFDictionary

    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
      return NSImage(contentsOf: url)
    }

    let thumbnailOptions = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
      return NSImage(contentsOf: url)
    }

    return NSImage(
      cgImage: cgImage,
      size: NSSize(width: CGFloat(cgImage.width) / resolvedScale, height: CGFloat(cgImage.height) / resolvedScale)
    )
  }

  private static func resolvedScale(_ scale: CGFloat) -> CGFloat {
    if scale > 0 { return scale }
    return NSScreen.main?.backingScaleFactor ?? 2
  }

  private static func cost(of image: NSImage) -> Int {
    var rect = CGRect(origin: .zero, size: image.size)
    if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
      return cgImage.width * cgImage.height * 4
    }

    return Int(max(image.size.width, 1) * max(image.size.height, 1) * 4)
  }

  func clearCache() {
    memoryCache.removeAllObjects()
    try? fileManager.removeItem(at: diskCacheURL)
    try? fileManager.createDirectory(
      at: diskCacheURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
  }
}

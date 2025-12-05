import AppKit
import Foundation
import Logger

final class ImageCacheManager {
  static let shared = ImageCacheManager()
  private let memoryCache = NSCache<NSString, NSImage>()
  private let syncQueue = DispatchQueue(
    label: "ImageCacheManager.syncQueue",
    qos: .userInitiated,
    attributes: [],
    autoreleaseFrequency: .workItem
  )
  private let asyncQueue = DispatchQueue(
    label: "ImageCacheManager.asyncQueue",
    qos: .utility,
    attributes: .concurrent
  )

  private let fileManager = FileManager.default
  private let diskCacheURL: URL

  private init() {
    memoryCache.countLimit = 100
    memoryCache.totalCostLimit = 1_024 * 1_024 * 100

    let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    diskCacheURL = cachesDirectory.appendingPathComponent("ImageCache")
    try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
  }

  func image(for url: URL, loadSync: Bool, cacheKey: String? = nil, completion: @escaping (NSImage?) -> Void) {
    let keyString = cacheKey ?? url.absoluteString
    let cacheKey = keyString as NSString

    // Memory cache check (always sync)
    if let cachedImage = memoryCache.object(forKey: cacheKey) {
      completion(cachedImage)
      return
    }

    if loadSync {
      // Synchronous path with proper QoS handling
      var diskImage: NSImage?
      syncQueue.sync {
        diskImage = self.loadFromDiskSync(key: keyString)
      }

      if let diskImage {
        memoryCache.setObject(diskImage, forKey: cacheKey)
        completion(diskImage)
        return
      }
    }

    // Asynchronous path

    // Asynchronous load with proper thread handling
    asyncQueue.async { [weak self] in
      guard let self else { return }

      // Check cache again in case it was populated while queued
      if let cachedImage = memoryCache.object(forKey: cacheKey) {
        DispatchQueue.main.async { completion(cachedImage) }
        return
      }

      // Load from local or remote URL
      guard let image = NSImage(contentsOf: url) else {
        DispatchQueue.main.async { completion(nil) }
        return
      }

      // Store in cache and return
      memoryCache.setObject(image, forKey: cacheKey)
      DispatchQueue.main.async { completion(image) }
    }
  }

  private func loadFromDiskSync(key: String) -> NSImage? {
    let diskKey = diskCacheKey(for: key)
    let diskPath = diskCacheURL.appendingPathComponent(diskKey)
    return NSImage(contentsOf: diskPath)
  }

  private func diskCacheKey(for key: String) -> String {
    key.data(using: .utf8)?.base64EncodedString() ?? UUID().uuidString
  }

  /// Fast in-memory lookup using an explicit cache key.
  func cachedImage(cacheKey: String) -> NSImage? {
    memoryCache.object(forKey: cacheKey as NSString)
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

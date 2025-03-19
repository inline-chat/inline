import AppKit

// MARK: - Enhanced Cell Cache with Message IDs

class TableViewCellCache<CellType: NSView> {
  private var cache: [String: CellType] = [:]
  private var lruKeys: [String] = [] // Tracks least recently used keys
  private let maxCacheSize: Int

  init(maxCacheSize: Int = 100) {
    self.maxCacheSize = maxCacheSize
  }

  /// Generate a cache key from cell type and message ID
  static func cacheKey(type: String, messageId: Int64) -> String {
    "\(type)_\(messageId)"
  }

  /// Get a cell from the cache or create a new one using the provided factory
  func dequeueCell(withType type: String, messageId: Int64, factory: () -> CellType) -> CellType {
    let key = TableViewCellCache.cacheKey(type: type, messageId: messageId)

    if let cell = cache[key] {
      // Move this key to the end of LRU list (most recently used)
      if let index = lruKeys.firstIndex(of: key) {
        lruKeys.remove(at: index)
      }
      lruKeys.append(key)
      return cell
    }

    // Create new cell
    return factory()
  }

  /// Store a cell in the cache
  func cacheCell(_ cell: CellType, withType type: String, messageId: Int64) {
    let key = TableViewCellCache.cacheKey(type: type, messageId: messageId)

    // If we're at capacity, remove least recently used cell
    if cache.count >= maxCacheSize, !lruKeys.isEmpty {
      let oldestKey = lruKeys.removeFirst()
      cache.removeValue(forKey: oldestKey)
    }

    // Store the cell and track it in LRU list
    cache[key] = cell
    lruKeys.append(key)
  }

  /// Remove a specific cell from cache
  func removeCell(withType type: String, messageId: Int64) {
    let key = TableViewCellCache.cacheKey(type: type, messageId: messageId)
    cache.removeValue(forKey: key)
    if let index = lruKeys.firstIndex(of: key) {
      lruKeys.remove(at: index)
    }
  }

  /// Clear the entire cache
  func clearCache() {
    cache.removeAll()
    lruKeys.removeAll()
  }

  /// Get current cache size
  var size: Int {
    cache.count
  }
}

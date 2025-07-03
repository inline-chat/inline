import Foundation

public actor UpdatesStateManager: Sendable {
  public static let shared = UpdatesStateManager()

  private let userDefaults = UserDefaults.standard
  private let dateKey = "UpdatesStateManager.lastUpdateDate"
  private let ptsKey = "UpdatesStateManager.lastPts"

  // RAM cache for fast lookups
  private var cachedDate: Int64?
  private var cachedPts: Int64?
  private var isDateCached = false
  private var isPtsCached = false

  public init() {}

  // MARK: - Date Management

  public func saveLastUpdateDate(_ date: Int64) {
    // Update cache immediately for fast subsequent reads
    cachedDate = date
    isDateCached = true

    // Persist to UserDefaults asynchronously to avoid blocking
    Task.detached {
      UserDefaults.standard.set(date, forKey: self.dateKey)
    }
  }

  public func getLastUpdateDate() -> Int64? {
    // Return from cache if available
    if isDateCached {
      return cachedDate
    }

    // Load from UserDefaults and cache
    if let date = userDefaults.object(forKey: dateKey) as? Int64 {
      cachedDate = date
      isDateCached = true
      return date
    }

    return nil
  }

  // MARK: - PTS Management

  public func saveLastPts(_ pts: Int64) {
    // Update cache immediately for fast subsequent reads
    cachedPts = pts
    isPtsCached = true

    // Persist to UserDefaults asynchronously to avoid blocking
    Task.detached {
      UserDefaults.standard.set(pts, forKey: self.ptsKey)
    }
  }

  public func getLastPts() -> Int64? {
    // Return from cache if available
    if isPtsCached {
      return cachedPts
    }

    // Load from UserDefaults and cache
    if let pts = userDefaults.object(forKey: ptsKey) as? Int64 {
      cachedPts = pts
      isPtsCached = true
      return pts
    }

    return nil
  }

  // MARK: - Convenience Methods

  public func clearState() {
    // Clear cache immediately
    cachedDate = nil
    cachedPts = nil
    isDateCached = false
    isPtsCached = false

    // Clear UserDefaults asynchronously to avoid blocking
    Task.detached {
      UserDefaults.standard.removeObject(forKey: self.dateKey)
      UserDefaults.standard.removeObject(forKey: self.ptsKey)
    }
  }

  public func hasStoredState() -> Bool {
    getLastUpdateDate() != nil || getLastPts() != nil
  }

  // MARK: - Cache Management

  public func invalidateCache() {
    cachedDate = nil
    cachedPts = nil
    isDateCached = false
    isPtsCached = false
  }

  public func refreshFromUserDefaults() {
    invalidateCache()
    // Force reload from UserDefaults on next access
  }
}

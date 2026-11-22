import Foundation
import InlineCompat
import Logger
import Observation

/// Drives the Data & Storage pages on both platforms.
@MainActor
public final class StorageUsageViewModel: CompatObservable {
  public let observationRegistrar = CompatObservationRegistrar()
  @Tracked public private(set) var report: StorageUsageReport? = nil
  /// The latest totals: from the report, or from the last scan until one finishes.
  @Tracked public private(set) var summary: StorageUsageSummary
  @Tracked public private(set) var isScanning = false
  @Tracked public private(set) var isClearing = false
  @Tracked public var selectedCategories: Set<StorageCategory> = Set(StorageCategory.allCases)
  @Tracked public private(set) var keepMedia: StorageKeepMedia = .current
  @Tracked public private(set) var cacheLimit: StorageCacheLimit = .current
  @Tracked public var errorMessage: String? = nil

  /// True once there is something to draw: a finished scan or the last one's totals.
  public var hasSummary: Bool { report != nil || hasCachedSummary }

  private let service: StorageUsageService
  private let hasCachedSummary: Bool
  private let log = Log.scoped("StorageUsageViewModel")

  public init(service: StorageUsageService = .shared) {
    self.service = service
    let cached = StorageUsageService.lastSummary
    summary = cached ?? .empty
    hasCachedSummary = cached != nil
  }

  // MARK: Categories

  /// Categories that hold anything, in display order.
  public var visibleCategories: [StorageCategory] {
    StorageCategory.allCases.filter { summary.bytes(for: $0) > 0 }
  }

  public func isSelected(_ category: StorageCategory) -> Bool {
    selectedCategories.contains(category) && removableBytes(for: category) > 0
  }

  public var selectedRemovableBytes: Int64 {
    report?.removableBytes(for: selectedCategories) ?? 0
  }

  public func removableBytes(for category: StorageCategory) -> Int64 {
    report?.removableBytes(for: [category]) ?? 0
  }

  public func count(for category: StorageCategory) -> Int {
    report?.count(for: category) ?? 0
  }

  public func toggle(_ category: StorageCategory) {
    if selectedCategories.contains(category) {
      selectedCategories.remove(category)
    } else {
      selectedCategories.insert(category)
    }
  }

  public var chats: [StorageChatUsage] { report?.chats ?? [] }

  public func chat(_ chatId: Int64) -> StorageChatUsage? {
    report?.chats.first { $0.chatId == chatId }
  }

  // MARK: Scan

  public func refresh() async {
    guard !isScanning else { return }
    isScanning = true
    defer { isScanning = false }
    do {
      let report = try await service.scan()
      self.report = report
      summary = report.summary
    } catch {
      log.error("Storage scan failed", error: error)
      errorMessage = "Storage couldn’t be measured. \(error.localizedDescription)"
    }
  }

  // MARK: Clear

  @discardableResult
  public func clearSelected() async -> StorageCleanupResult? {
    await clear(categories: selectedCategories)
  }

  @discardableResult
  public func clear(categories: Set<StorageCategory>, chatId: Int64? = nil) async -> StorageCleanupResult? {
    guard let report else { return nil }
    let items = report.items.filter { item in
      categories.contains(item.category) && (chatId == nil || item.chatId == chatId)
    }
    return await remove(items)
  }

  @discardableResult
  public func remove(_ items: [StorageItem]) async -> StorageCleanupResult? {
    guard !isClearing, !items.isEmpty else { return nil }
    isClearing = true
    defer { isClearing = false }
    do {
      let result = try await service.remove(items)
      await rescanAfterChange()
      return result
    } catch {
      log.error("Storage cleanup failed", error: error)
      errorMessage = "Downloads couldn’t be removed. \(error.localizedDescription)"
      await rescanAfterChange()
      return nil
    }
  }

  private func rescanAfterChange() async {
    // A scan in flight started before the removal; wait it out, then measure again.
    while isScanning {
      try? await Task.sleep(for: .milliseconds(50))
    }
    await refresh()
  }

  // MARK: Automatic Cleanup

  /// Bytes the given settings would remove right now.
  public func cleanupBytes(keepMedia: StorageKeepMedia? = nil, cacheLimit: StorageCacheLimit? = nil) -> Int64 {
    guard let report else { return 0 }
    return StorageUsageService.cleanupItems(
      in: report,
      keepMedia: keepMedia ?? self.keepMedia,
      cacheLimit: cacheLimit ?? self.cacheLimit,
      now: Date()
    )
    .reduce(0) { $0 + $1.bytes }
  }

  @discardableResult
  public func setKeepMedia(_ value: StorageKeepMedia) async -> StorageCleanupResult? {
    keepMedia = value
    StorageKeepMedia.current = value
    return await applyAutomaticCleanup()
  }

  @discardableResult
  public func setCacheLimit(_ value: StorageCacheLimit) async -> StorageCleanupResult? {
    cacheLimit = value
    StorageCacheLimit.current = value
    return await applyAutomaticCleanup()
  }

  private func applyAutomaticCleanup() async -> StorageCleanupResult? {
    guard let report else { return nil }
    let items = StorageUsageService.cleanupItems(in: report, keepMedia: keepMedia, cacheLimit: cacheLimit, now: Date())
    return await remove(items)
  }
}

@available(iOS 17.0, macOS 14.0, *)
extension StorageUsageViewModel: Observable {}

public extension Int64 {
  /// Byte count formatted the way Finder shows file sizes.
  var storageFormatted: String {
    ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
  }
}

public extension AutoDownloadSettingsManager {
  /// Size limits offered in the auto-download menus, in megabytes. 0 is Off.
  static func sizeOptions(for kind: AutoDownloadKind, including current: Int) -> [Int] {
    let options: [Int] = switch kind {
      case .media, .file: [0, 1, 5, 10, 25, 50, 100, 250, 500, 1_024, 2_048]
      case .voice: [0, 1, 5, 10, 25, 50]
    }
    let current = clamped(current)
    return options.contains(current) ? options : (options + [current]).sorted()
  }

  static func sizeLabel(_ megabytes: Int) -> String {
    guard megabytes > 0 else { return "Off" }
    let size = megabytes >= 1_024 && megabytes % 1_024 == 0 ? "\(megabytes / 1_024) GB" : "\(megabytes) MB"
    return "Up to \(size)"
  }
}

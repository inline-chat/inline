import Foundation
import GRDB
import InlineConfig
import Logger

// MARK: - Model

/// What the Data & Storage page groups downloads into.
public enum StorageCategory: String, CaseIterable, Sendable, Identifiable, Hashable, Codable {
  case photos
  case videos
  case files
  case voice
  /// Profile photos and files no message refers to any more.
  case other

  public var id: String { rawValue }

  public var title: String {
    switch self {
      case .photos: "Photos"
      case .videos: "Videos"
      case .files: "Files"
      case .voice: "Voice Messages"
      case .other: "Other"
    }
  }

  public var systemImage: String {
    switch self {
      case .photos: "photo.fill"
      case .videos: "video.fill"
      case .files: "doc.fill"
      case .voice: "waveform"
      case .other: "square.stack.3d.up.fill"
    }
  }
}

/// One downloaded file on this device.
public struct StorageItem: Identifiable, Sendable, Hashable {
  public struct ID: Hashable, Sendable {
    public let folder: FileLocalCacheDirectory
    public let fileName: String
  }

  public enum Protection: String, Sendable, Hashable {
    /// Attached to a draft.
    case draft
    /// Belongs to a message that has not been sent yet.
    case unsent
    /// Nothing refers to it yet, and it changed a moment ago: an upload being prepared.
    case recent
    /// Something other than a message still points at it, or a draft could not be read.
    case inUse
  }

  public let id: ID
  public let category: StorageCategory
  public let displayName: String
  public let url: URL
  public let bytes: Int64
  /// When the file last arrived or changed on this device.
  public let fileDate: Date
  public let messageDate: Date?
  public let chatId: Int64?
  public let messageId: Int64?
  public let isProfilePhoto: Bool
  public let protection: Protection?

  public var isRemovable: Bool { protection == nil }
  public var folder: FileLocalCacheDirectory { id.folder }
  public var date: Date { messageDate ?? fileDate }
}

public struct StorageChatUsage: Identifiable, Sendable, Hashable {
  public let chatId: Int64
  public let chat: Chat?
  public let user: UserInfo?
  public let title: String
  public let bytes: Int64
  public let removableBytes: Int64
  public let itemCount: Int
  public let bytesByCategory: [StorageCategory: Int64]

  public var id: Int64 { chatId }
}

public struct StorageUsageReport: Sendable {
  public let items: [StorageItem]
  public let chats: [StorageChatUsage]
  public let databaseBytes: Int64
  public let scannedAt: Date

  public init(items: [StorageItem], chats: [StorageChatUsage], databaseBytes: Int64, scannedAt: Date) {
    self.items = items
    self.chats = chats
    self.databaseBytes = databaseBytes
    self.scannedAt = scannedAt
  }

  public var mediaBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
  public var totalBytes: Int64 { mediaBytes + databaseBytes }
  public var removableBytes: Int64 { items.reduce(0) { $0 + ($1.isRemovable ? $1.bytes : 0) } }

  public func bytes(for category: StorageCategory) -> Int64 {
    items.reduce(0) { $0 + ($1.category == category ? $1.bytes : 0) }
  }

  public func removableBytes(for categories: Set<StorageCategory>) -> Int64 {
    items.reduce(0) { $0 + ($1.isRemovable && categories.contains($1.category) ? $1.bytes : 0) }
  }

  public func count(for category: StorageCategory) -> Int {
    items.reduce(0) { $0 + ($1.category == category ? 1 : 0) }
  }

  public func items(in category: StorageCategory) -> [StorageItem] {
    items.filter { $0.category == category }
  }

  public func items(inChat chatId: Int64) -> [StorageItem] {
    items.filter { $0.chatId == chatId }
  }

  /// Category totals, the part of a report worth remembering between launches.
  public var summary: StorageUsageSummary {
    StorageUsageSummary(
      bytesByCategory: Dictionary(uniqueKeysWithValues: StorageCategory.allCases.map { ($0, bytes(for: $0)) }),
      databaseBytes: databaseBytes,
      removableBytes: removableBytes
    )
  }
}

/// Category totals kept from the last scan so the page draws its chart on the first frame.
public struct StorageUsageSummary: Codable, Sendable, Equatable {
  public var bytesByCategory: [StorageCategory: Int64]
  public var databaseBytes: Int64
  public var removableBytes: Int64

  public init(bytesByCategory: [StorageCategory: Int64], databaseBytes: Int64, removableBytes: Int64) {
    self.bytesByCategory = bytesByCategory
    self.databaseBytes = databaseBytes
    self.removableBytes = removableBytes
  }

  public static let empty = StorageUsageSummary(bytesByCategory: [:], databaseBytes: 0, removableBytes: 0)

  public func bytes(for category: StorageCategory) -> Int64 { bytesByCategory[category] ?? 0 }
  public var mediaBytes: Int64 { bytesByCategory.values.reduce(0, +) }
  public var totalBytes: Int64 { mediaBytes + databaseBytes }
}

public struct StorageCleanupResult: Sendable, Equatable {
  public var removed = 0
  public var removedBytes: Int64 = 0
  public var skipped = 0
  public var failed = 0

  public init() {}
}

/// How long downloads stay on this device before Inline removes them.
public enum StorageKeepMedia: Int, CaseIterable, Sendable, Identifiable {
  case week = 7
  case month = 30
  case threeMonths = 90
  case forever = 0

  public var id: Int { rawValue }

  public var title: String {
    switch self {
      case .week: "1 Week"
      case .month: "1 Month"
      case .threeMonths: "3 Months"
      case .forever: "Forever"
    }
  }

  public var maxAge: TimeInterval? {
    rawValue > 0 ? TimeInterval(rawValue) * 24 * 60 * 60 : nil
  }

  static let defaultsKey = "storage.keepMediaDays"

  public static var current: StorageKeepMedia {
    get {
      guard UserDefaults.shared.object(forKey: defaultsKey) != nil else { return .forever }
      return StorageKeepMedia(rawValue: UserDefaults.shared.integer(forKey: defaultsKey)) ?? .forever
    }
    set { UserDefaults.shared.set(newValue.rawValue, forKey: defaultsKey) }
  }
}

/// The most space downloads may take on this device before the oldest are removed.
public enum StorageCacheLimit: Int, CaseIterable, Sendable, Identifiable {
  case gb1 = 1
  case gb5 = 5
  case gb10 = 10
  case gb25 = 25
  case unlimited = 0

  public var id: Int { rawValue }

  public var title: String {
    rawValue > 0 ? "\(rawValue) GB" : "No Limit"
  }

  public var maxBytes: Int64? {
    rawValue > 0 ? Int64(rawValue) * 1_000_000_000 : nil
  }

  static let defaultsKey = "storage.cacheLimitGB"

  public static var current: StorageCacheLimit {
    get {
      guard UserDefaults.shared.object(forKey: defaultsKey) != nil else { return .unlimited }
      return StorageCacheLimit(rawValue: UserDefaults.shared.integer(forKey: defaultsKey)) ?? .unlimited
    }
    set { UserDefaults.shared.set(newValue.rawValue, forKey: defaultsKey) }
  }
}

// MARK: - Service

/// Measures and removes downloaded media on this device.
///
/// Removal drops the file and the database's pointer to it, so the media is downloaded again
/// when someone opens it. Files a draft or an unsent message needs are never removed, and
/// neither are unreferenced files that changed in the last hour (an upload being prepared).
public actor StorageUsageService {
  public static let shared = StorageUsageService()

  static let recentUnreferencedAge: TimeInterval = 60 * 60
  static let autoCleanupStampName = ".storage-cleanup-last-run"
  static let summaryDefaultsKey = "storage.lastSummary"

  private let log = Log.scoped("StorageUsage")
  private let databaseProvider: @Sendable () -> AppDatabase
  private let folderProvider: @Sendable () -> [FileLocalCacheDirectory: URL]

  init(
    database: @escaping @Sendable () -> AppDatabase = { AppDatabase.shared },
    folders: @escaping @Sendable () -> [FileLocalCacheDirectory: URL] = {
      Dictionary(uniqueKeysWithValues: LegacyMediaCacheMigration.kinds.map {
        ($0, FileHelpers.getLocalCacheDirectory(for: $0, createIfNeeded: false))
      })
    }
  ) {
    databaseProvider = database
    folderProvider = folders
  }

  /// The folder that holds this device's downloads.
  public nonisolated static var mediaFolderURL: URL { FileHelpers.mediaCacheRoot() }

  /// The last scan's totals, for drawing the page before a scan finishes.
  public nonisolated static var lastSummary: StorageUsageSummary? {
    guard let data = UserDefaults.shared.data(forKey: summaryDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(StorageUsageSummary.self, from: data)
  }

  private nonisolated static func remember(_ summary: StorageUsageSummary) {
    guard let data = try? JSONEncoder().encode(summary) else { return }
    UserDefaults.shared.set(data, forKey: summaryDefaultsKey)
  }

  // MARK: Scan

  public func scan(now: Date = Date()) async throws -> StorageUsageReport {
    let database = databaseProvider()
    // List files first, then read references, so a reference added meanwhile is still seen.
    let files = Self.listFiles(in: folderProvider())
    let references = try await database.dbWriter.read { db in try Self.readReferences(db) }

    let items = files
      .map { Self.item(for: $0, references: references, now: now) }
      .sorted { $0.bytes > $1.bytes }

    let chats = try await database.dbWriter.read { db in
      try Self.chatUsage(for: items, db: db)
    }
    let report = StorageUsageReport(
      items: items,
      chats: chats,
      databaseBytes: Self.databaseBytes(path: database.dbWriter.path),
      scannedAt: now
    )
    Self.remember(report.summary)
    return report
  }

  struct ListedFile: Sendable {
    let folder: FileLocalCacheDirectory
    let url: URL
    let bytes: Int64
    /// Last use: arrival, change, or read.
    let date: Date
    /// Arrival or change only; reading a file doesn't make it new.
    let arrived: Date
  }

  static func listFiles(in folders: [FileLocalCacheDirectory: URL]) -> [ListedFile] {
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey,
      .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .attributeModificationDateKey,
    ]
    var result: [ListedFile] = []
    for (folder, directory) in folders {
      let contents = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
      )) ?? []
      for url in contents where MediaCacheSweep.isSweepable(url.lastPathComponent) {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true, values.isSymbolicLink != true
        else { continue }
        let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        // A copy keeps its source's dates; its attribute change date is when it arrived.
        let arrived = [values.creationDate, values.contentModificationDate, values.attributeModificationDate]
          .compactMap(\.self).max() ?? .distantPast
        let date = max(arrived, values.contentAccessDate ?? .distantPast)
        result.append(ListedFile(folder: folder, url: url, bytes: bytes, date: date, arrived: arrived))
      }
    }
    return result
  }

  struct Owner: Sendable {
    var chatId: Int64?
    var messageId: Int64?
    var date: Date?
    var unsent = false
    var displayName: String?

    /// Keeps the newest message as the owner; any unsent owner protects the file.
    mutating func merge(_ other: Owner) {
      unsent = unsent || other.unsent
      if displayName == nil { displayName = other.displayName }
      guard let otherDate = other.date else { return }
      if date.map({ otherDate > $0 }) ?? true {
        chatId = other.chatId
        messageId = other.messageId
        date = otherDate
      }
    }
  }

  struct References: Sendable {
    var owners: [FileLocalCacheDirectory: [String: Owner]] = [:]
    var avatars: Set<String> = []
    var drafts: [FileLocalCacheDirectory: Set<String>] = [:]
    /// Names the legacy `file` table points at; kept in every folder, as the sweep does.
    var pinned: Set<String> = []
    /// A draft could not be read, so any file nothing else refers to may be its attachment.
    var hasUnreadableDraft = false

    mutating func add(_ folder: FileLocalCacheDirectory, _ name: String, _ owner: Owner) {
      owners[folder, default: [:]][name, default: Owner()].merge(owner)
    }

    func isDraft(_ folder: FileLocalCacheDirectory, _ name: String) -> Bool {
      drafts[folder]?.contains(name) ?? false
    }

    /// Why a file must stay right now, if it must.
    func protection(
      _ folder: FileLocalCacheDirectory, _ name: String, arrived: Date?, now: Date
    ) -> StorageItem.Protection? {
      let owner = owners[folder]?[name]
      let isReferenced = owner != nil || (folder == .photos && avatars.contains(name))
      if isDraft(folder, name) { return .draft }
      if owner?.unsent == true { return .unsent }
      if pinned.contains(name) { return .inUse }
      guard !isReferenced else { return nil }
      if hasUnreadableDraft { return .inUse }
      if let arrived, now.timeIntervalSince(arrived) < StorageUsageService.recentUnreferencedAge { return .recent }
      return nil
    }
  }

  static func readReferences(_ db: Database) throws -> References {
    var references = References()

    func owner(_ row: Row, name: String? = nil) -> Owner {
      let status: Int64? = row["status"]
      return Owner(
        chatId: row["chatId"],
        messageId: row["messageId"],
        date: row["date"],
        unsent: status.flatMap(MessageSendingStatus.init(rawValue:)).map { $0 != .sent } ?? false,
        displayName: name
      )
    }

    // Every referenced path, so a row without a message still counts as in use.
    for (folder, names) in try LegacyMediaCacheMigration.referencedLocalPaths(db) {
      for name in names {
        references.owners[folder, default: [:]][name] = references.owners[folder]?[name] ?? Owner()
      }
    }

    let photoQueries = [
      // A photo message.
      """
      SELECT ps.localPath AS path, m.chatId, m.messageId, m.date, m.status
      FROM photoSize ps JOIN photo p ON p.id = ps.photoId JOIN message m ON m.photoId = p.photoId
      WHERE ps.localPath IS NOT NULL AND ps.localPath != ''
      """,
      // A video's or a document's thumbnail.
      """
      SELECT ps.localPath AS path, m.chatId, m.messageId, m.date, m.status
      FROM photoSize ps JOIN video v ON v.thumbnailPhotoId = ps.photoId JOIN message m ON m.videoId = v.videoId
      WHERE ps.localPath IS NOT NULL AND ps.localPath != ''
      """,
      """
      SELECT ps.localPath AS path, m.chatId, m.messageId, m.date, m.status
      FROM photoSize ps JOIN document d ON d.thumbnailPhotoId = ps.photoId JOIN message m ON m.documentId = d.documentId
      WHERE ps.localPath IS NOT NULL AND ps.localPath != ''
      """,
    ]
    for sql in photoQueries {
      let rows = try Row.fetchCursor(db, sql: sql)
      while let row = try rows.next() {
        guard let path: String = row["path"] else { continue }
        references.add(.photos, path, owner(row))
      }
    }

    let videoRows = try Row.fetchCursor(db, sql: """
      SELECT v.localPath AS path, m.chatId, m.messageId, m.date, m.status
      FROM video v JOIN message m ON m.videoId = v.videoId
      WHERE v.localPath IS NOT NULL AND v.localPath != ''
      """)
    while let row = try videoRows.next() {
      guard let path: String = row["path"] else { continue }
      references.add(.videos, path, owner(row))
    }

    let documentRows = try Row.fetchCursor(db, sql: """
      SELECT d.localPath AS path, d.fileName, m.chatId, m.messageId, m.date, m.status
      FROM document d LEFT JOIN message m ON m.documentId = d.documentId
      WHERE d.localPath IS NOT NULL AND d.localPath != ''
      """)
    while let row = try documentRows.next() {
      guard let path: String = row["path"] else { continue }
      let fileName: String? = row["fileName"]
      references.add(.documents, path, owner(row, name: fileName.flatMap { $0.isEmpty ? nil : $0 }))
    }

    let voiceMessages = try Message.filter(sql: "contentPayload IS NOT NULL").fetchCursor(db)
    while let message = try voiceMessages.next() {
      guard let path = message.voiceLocalRelativePath else { continue }
      references.add(.voices, path, Owner(
        chatId: message.chatId,
        messageId: message.messageId,
        date: message.date,
        unsent: message.status.map { $0 != .sent } ?? false
      ))
    }

    references.avatars = Set(try String.fetchAll(
      db, sql: "SELECT profileLocalPath FROM user WHERE profileLocalPath IS NOT NULL AND profileLocalPath != ''"
    ))

    references.pinned = Set(try String.fetchAll(
      db, sql: "SELECT localPath FROM \(File.databaseTableName) WHERE localPath IS NOT NULL AND localPath != ''"
    ))

    // Drafts own their attachments. A draft that cannot be read might hold any unreferenced file.
    (references.drafts, references.hasUnreadableDraft) = try draftReferencedNames(db)
    return references
  }

  /// Names attached to drafts, by folder, and whether any draft could not be read.
  static func draftReferencedNames(_ db: Database) throws -> ([FileLocalCacheDirectory: Set<String>], Bool) {
    var names: [FileLocalCacheDirectory: Set<String>] = [:]
    var unreadable = false
    let blobs = try Data.fetchAll(
      db, sql: "SELECT attachments FROM \(Drafts2Row.databaseTableName) WHERE attachments IS NOT NULL"
    )
    func add(_ kind: FileLocalCacheDirectory, _ name: String?) {
      guard let name, !name.isEmpty else { return }
      names[kind, default: []].insert(name)
    }
    for blob in blobs {
      guard let attachments = try? JSONDecoder().decode(Drafts2AttachmentBlob.self, from: blob).attachments else {
        unreadable = true
        continue
      }
      for attachment in attachments {
        switch attachment.media {
          case let .photo(photo):
            photo.sizes.forEach { add(.photos, $0.localPath) }
          case let .video(video):
            add(.videos, video.video.localPath)
            video.thumbnail?.sizes.forEach { add(.photos, $0.localPath) }
          case let .document(document):
            add(.documents, document.document.localPath)
            document.thumbnail?.sizes.forEach { add(.photos, $0.localPath) }
          case let .voice(voice):
            add(.voices, voice.localRelativePath.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }
    }
    return (names, unreadable)
  }

  static func item(for file: ListedFile, references: References, now: Date) -> StorageItem {
    let name = file.url.lastPathComponent
    let owner = references.owners[file.folder]?[name]
    let isAvatar = file.folder == .photos && references.avatars.contains(name)
    let isReferenced = owner != nil || isAvatar

    let protection = references.protection(file.folder, name, arrived: file.arrived, now: now)

    let category: StorageCategory =
      if isAvatar || !isReferenced {
        .other
      } else {
        switch file.folder {
          case .photos: .photos
          case .videos: .videos
          case .documents: .files
          case .voices: .voice
        }
      }

    let displayName: String =
      if let name = owner?.displayName {
        name
      } else if isAvatar {
        "Profile Photo"
      } else if !isReferenced {
        "Unused File"
      } else {
        switch file.folder {
          case .photos: "Photo"
          case .videos: "Video"
          case .documents: "File"
          case .voices: "Voice Message"
        }
      }

    return StorageItem(
      id: .init(folder: file.folder, fileName: name),
      category: category,
      displayName: displayName,
      url: file.url,
      bytes: file.bytes,
      fileDate: file.date,
      messageDate: owner?.date,
      chatId: owner?.chatId,
      messageId: owner?.messageId,
      isProfilePhoto: isAvatar,
      protection: protection
    )
  }

  static func chatUsage(for items: [StorageItem], db: Database) throws -> [StorageChatUsage] {
    struct Totals {
      var bytes: Int64 = 0
      var removable: Int64 = 0
      var count = 0
      var byCategory: [StorageCategory: Int64] = [:]
    }
    var totals: [Int64: Totals] = [:]
    for item in items {
      guard let chatId = item.chatId else { continue }
      totals[chatId, default: Totals()].bytes += item.bytes
      totals[chatId, default: Totals()].count += 1
      totals[chatId, default: Totals()].byCategory[item.category, default: 0] += item.bytes
      if item.isRemovable { totals[chatId, default: Totals()].removable += item.bytes }
    }

    let chats = try Chat.filter(keys: Array(totals.keys)).fetchAll(db)
    let chatsById = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let userIds = chats.compactMap(\.peerUserId)
    let users = try User.userInfoQuery().filter(userIds.contains(Column("id"))).fetchAll(db)
    let usersById = Dictionary(users.map { ($0.user.id, $0) }, uniquingKeysWith: { first, _ in first })

    return totals.map { chatId, totals in
      let chat = chatsById[chatId]
      let user = chat?.peerUserId.flatMap { usersById[$0] }
      let title: String =
        if let user {
          user.user.displayName
        } else if let title = chat?.title, !title.isEmpty {
          [chat?.emoji, title].compactMap(\.self).joined(separator: " ")
        } else {
          "Chat"
        }
      return StorageChatUsage(
        chatId: chatId,
        chat: chat,
        user: user,
        title: title,
        bytes: totals.bytes,
        removableBytes: totals.removable,
        itemCount: totals.count,
        bytesByCategory: totals.byCategory
      )
    }
    .sorted { $0.bytes > $1.bytes }
  }

  static func databaseBytes(path: String) -> Int64 {
    ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
      let url = URL(fileURLWithPath: path + suffix)
      let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
      return total + Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
  }

  // MARK: Remove

  /// Removes the given downloads. Protected files are skipped, checked again right now.
  @discardableResult
  public func remove(_ items: [StorageItem], now: Date = Date()) async throws -> StorageCleanupResult {
    var result = StorageCleanupResult()
    let candidates = items.filter(\.isRemovable)
    result.skipped = items.count - candidates.count
    guard !candidates.isEmpty else { return result }

    let database = databaseProvider()
    // Fresh look at what must stay: a draft or a send may have started since the scan.
    let references = try await database.dbWriter.read { db in try Self.readReferences(db) }

    var removed: [FileLocalCacheDirectory: [String]] = [:]
    var voiceOwners: [(chatId: Int64, messageId: Int64)] = []
    for item in candidates {
      let name = item.id.fileName
      let owner = references.owners[item.folder]?[name]
      if references.protection(item.folder, name, arrived: Self.arrivalDate(item.url), now: now) != nil {
        result.skipped += 1
        continue
      }

      do {
        if FileManager.default.fileExists(atPath: item.url.path) {
          try FileManager.default.removeItem(at: item.url)
        }
        result.removed += 1
        result.removedBytes += item.bytes
        removed[item.folder, default: []].append(name)
        if item.folder == .voices, let chatId = owner?.chatId ?? item.chatId,
           let messageId = owner?.messageId ?? item.messageId
        {
          voiceOwners.append((chatId, messageId))
        }
      } catch {
        result.failed += 1
        log.error("Failed to remove \(item.folder) download", error: error)
      }
    }

    guard !removed.isEmpty else { return result }
    let removedNames = removed
    let voices = voiceOwners
    try await database.dbWriter.write { db in
      try Self.clearPointers(removedNames, voices: voices, db: db)
    }
    log.info("Removed downloads removed=\(result.removed) bytes=\(result.removedBytes) skipped=\(result.skipped) failed=\(result.failed)")
    return result
  }

  private static func arrivalDate(_ url: URL) -> Date? {
    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .attributeModificationDateKey])
    return [values?.creationDate, values?.contentModificationDate, values?.attributeModificationDate]
      .compactMap(\.self).max()
  }

  /// Points every row that used a removed file back at the server copy.
  static func clearPointers(
    _ removed: [FileLocalCacheDirectory: [String]],
    voices: [(chatId: Int64, messageId: Int64)],
    db: Database
  ) throws {
    func clear(_ table: String, _ column: String, _ names: [String]) throws {
      for chunk in stride(from: 0, to: names.count, by: 400).map({ Array(names[$0 ..< min($0 + 400, names.count)]) }) {
        let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
        try db.execute(
          sql: "UPDATE \(table) SET \(column) = NULL WHERE \(column) IN (\(placeholders))",
          arguments: StatementArguments(chunk)
        )
      }
    }

    if let photos = removed[.photos] {
      try clear(PhotoSize.databaseTableName, "localPath", photos)
      try clear(User.databaseTableName, "profileLocalPath", photos)
    }
    if let videos = removed[.videos] { try clear(Video.databaseTableName, "localPath", videos) }
    if let documents = removed[.documents] { try clear(Document.databaseTableName, "localPath", documents) }
    if let voiceNames = removed[.voices] {
      let names = Set(voiceNames)
      for owner in voices {
        guard var message = try Message.fetchOne(db, key: ["messageId": owner.messageId, "chatId": owner.chatId]),
              let path = message.voiceLocalRelativePath, names.contains(path)
        else { continue }
        message.setVoiceLocalRelativePath(nil)
        try message.saveMessage(db)
      }
    }
  }

  // MARK: Automatic Cleanup

  /// Downloads from chats that Keep Media and the cache limit would remove now. Profile photos,
  /// unused files (the daily sweep handles those) and protected files are left alone.
  public static func cleanupItems(
    in report: StorageUsageReport,
    keepMedia: StorageKeepMedia,
    cacheLimit: StorageCacheLimit,
    now: Date
  ) -> [StorageItem] {
    let candidates = report.items
      .filter { $0.isRemovable && $0.chatId != nil && !$0.isProfilePhoto }
      .sorted { $0.fileDate < $1.fileDate }
    var chosen = Set<StorageItem.ID>()
    var result: [StorageItem] = []
    var remaining = report.mediaBytes

    if let maxAge = keepMedia.maxAge {
      for item in candidates where now.timeIntervalSince(item.fileDate) >= maxAge {
        chosen.insert(item.id)
        result.append(item)
        remaining -= item.bytes
      }
    }
    // Least recently used first, until downloads fit.
    if let maxBytes = cacheLimit.maxBytes {
      for item in candidates where remaining > maxBytes && !chosen.contains(item.id) {
        chosen.insert(item.id)
        result.append(item)
        remaining -= item.bytes
      }
    }
    return result
  }

  /// Applies Keep Media and the cache limit now, whatever the schedule says.
  @discardableResult
  public func applyAutomaticCleanup(
    keepMedia: StorageKeepMedia = .current,
    cacheLimit: StorageCacheLimit = .current,
    now: Date = Date()
  ) async throws -> StorageCleanupResult {
    guard keepMedia != .forever || cacheLimit != .unlimited else { return StorageCleanupResult() }
    let report = try await scan(now: now)
    let items = Self.cleanupItems(in: report, keepMedia: keepMedia, cacheLimit: cacheLimit, now: now)
    guard !items.isEmpty else { return StorageCleanupResult() }
    return try await remove(items, now: now)
  }

  /// Applies automatic cleanup once a day, after the media sweep.
  func applyAutomaticCleanupIfDue(root: URL = FileHelpers.mediaCacheRoot(), now: Date = Date()) async {
    let keepMedia = StorageKeepMedia.current
    let cacheLimit = StorageCacheLimit.current
    guard keepMedia != .forever || cacheLimit != .unlimited else { return }
    let stamp = root.appendingPathComponent(Self.autoCleanupStampName)
    if let last = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
       now.timeIntervalSince(last) < MediaCacheSweep.interval, last <= now
    {
      return
    }
    do {
      let result = try await applyAutomaticCleanup(keepMedia: keepMedia, cacheLimit: cacheLimit, now: now)
      log.info("Automatic storage cleanup removed=\(result.removed) bytes=\(result.removedBytes)")
    } catch {
      log.error("Automatic storage cleanup failed", error: error)
    }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? Data().write(to: stamp, options: .atomic)
  }
}

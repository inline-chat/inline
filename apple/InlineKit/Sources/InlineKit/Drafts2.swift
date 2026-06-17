import Foundation
import GRDB
import InlineProtocol
import Logger

public struct Drafts2Attachment: Codable, Sendable {
  public var id: String
  public var media: FileMediaItem
  public var createdAt: Int64

  public init(id: String, media: FileMediaItem, createdAt: Int64 = Drafts2.nowSeconds()) {
    self.id = id
    self.media = media
    self.createdAt = createdAt
  }
}

public struct Drafts2Snapshot: Sendable {
  public var peer: Peer
  public var text: String
  public var entities: MessageEntities?
  public var attachments: [Drafts2Attachment]
  public var revision: Int64
  public var updatedAt: Int64

  public var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
  }

  public init(
    peer: Peer,
    text: String = "",
    entities: MessageEntities? = nil,
    attachments: [Drafts2Attachment] = [],
    revision: Int64 = 0,
    updatedAt: Int64 = Drafts2.nowSeconds()
  ) {
    self.peer = peer
    self.text = text
    self.entities = entities
    self.attachments = attachments
    self.revision = revision
    self.updatedAt = updatedAt
  }
}

public struct Drafts2SendSnapshot: Sendable {
  public var text: String?
  public var entities: MessageEntities?
  public var mediaItems: [FileMediaItem]

  public init(text: String?, entities: MessageEntities?, mediaItems: [FileMediaItem]) {
    self.text = text
    self.entities = entities
    self.mediaItems = mediaItems
  }
}

public enum Drafts2AttachmentResult: Sendable {
  case success(pendingId: String, attachment: Drafts2Attachment)
  case failure(pendingId: String, message: String)
}

public typealias Drafts2AttachmentCompletion = @MainActor @Sendable (Drafts2AttachmentResult) -> Void

struct Drafts2AttachmentBlob: Codable, Sendable, DatabaseValueConvertible {
  var attachments: [Drafts2Attachment]

  var databaseValue: DatabaseValue {
    do {
      return try JSONEncoder().encode(self).databaseValue
    } catch {
      Log.shared.error("Failed to encode Drafts2 attachments", error: error)
      return DatabaseValue.null
    }
  }

  static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Drafts2AttachmentBlob? {
    guard let data = Data.fromDatabaseValue(dbValue) else { return nil }

    do {
      return try JSONDecoder().decode(Drafts2AttachmentBlob.self, from: data)
    } catch {
      Log.shared.error("Failed to decode Drafts2 attachments", error: error)
      return nil
    }
  }
}

struct Drafts2Row: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable {
  static let databaseTableName = "draft2"

  var peerKey: String
  var text: String
  var entities: MessageEntities?
  var attachments: Drafts2AttachmentBlob?
  var updatedAt: Int64
  var revision: Int64

  enum Columns {
    static let peerKey = Column(CodingKeys.peerKey)
    static let revision = Column(CodingKeys.revision)
  }

  init(snapshot: Drafts2Snapshot) {
    peerKey = snapshot.peer.toString()
    text = snapshot.text
    entities = Drafts2.normalizedEntities(snapshot.entities)
    attachments = snapshot.attachments.isEmpty ? nil : Drafts2AttachmentBlob(attachments: snapshot.attachments)
    updatedAt = snapshot.updatedAt
    revision = snapshot.revision
  }

  func snapshot(peer: Peer) -> Drafts2Snapshot {
    Drafts2Snapshot(
      peer: peer,
      text: text,
      entities: Drafts2.normalizedEntities(entities),
      attachments: attachments?.attachments ?? [],
      revision: revision,
      updatedAt: updatedAt
    )
  }
}

private enum Drafts2PersistenceOperation: Sendable {
  case save(Drafts2Row)
  case clear(peerKey: String, revision: Int64)

  var peerKey: String {
    switch self {
      case let .save(row):
        row.peerKey
      case let .clear(peerKey, _):
        peerKey
    }
  }

  var revision: Int64 {
    switch self {
      case let .save(row):
        row.revision
      case let .clear(_, revision):
        revision
    }
  }
}

private final class Drafts2PersistenceWriter: @unchecked Sendable {
  private let database: AppDatabase
  private let log = Log.scoped("Drafts2PersistenceWriter")
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "chat.inline.Drafts2.persistence", qos: .utility)

  private var pending: [String: Drafts2PersistenceOperation] = [:]
  private var isDraining = false

  init(database: AppDatabase) {
    self.database = database
  }

  func save(_ row: Drafts2Row) {
    enqueue(.save(row))
  }

  func clear(peerKey: String, revision: Int64) {
    enqueue(.clear(peerKey: peerKey, revision: revision))
  }

  func flushBlocking() {
    queue.sync {
      drain()
    }
  }

  func flush() async {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        self?.drain()
        continuation.resume()
      }
    }
  }

  private func enqueue(_ operation: Drafts2PersistenceOperation) {
    var shouldStartDrain = false

    lock.lock()
    if let existing = pending[operation.peerKey], existing.revision > operation.revision {
      lock.unlock()
      return
    }
    pending[operation.peerKey] = operation
    if !isDraining {
      isDraining = true
      shouldStartDrain = true
    }
    lock.unlock()

    if shouldStartDrain {
      queue.async { [weak self] in
        self?.drain()
      }
    }
  }

  private func drain() {
    while true {
      let operations = nextBatch()
      guard !operations.isEmpty else { return }
      write(operations)
    }
  }

  private func nextBatch() -> [Drafts2PersistenceOperation] {
    lock.lock()
    defer { lock.unlock() }

    guard !pending.isEmpty else {
      isDraining = false
      return []
    }

    let operations = Array(pending.values)
    pending.removeAll()
    return operations
  }

  private func write(_ operations: [Drafts2PersistenceOperation]) {
    do {
      try database.dbWriter.write { db in
        for operation in operations {
          let existing = try Drafts2Row.fetchOne(db, key: operation.peerKey)
          guard (existing?.revision ?? 0) <= operation.revision else { continue }

          switch operation {
            case let .save(row):
              try row.save(db)
            case let .clear(peerKey, _):
              try Drafts2Row.filter(Drafts2Row.Columns.peerKey == peerKey).deleteAll(db)
          }
        }
      }
    } catch {
      log.error("Failed to persist Drafts2 batch", error: error)
    }
  }
}

public final class Drafts2: @unchecked Sendable {
  private let database: AppDatabase
  private let writer: Drafts2PersistenceWriter
  private let log = Log.scoped("Drafts2")
  private let stateQueue = DispatchQueue(label: "chat.inline.Drafts2.state")
  private var loadedPeerKeys: Set<String> = []
  private var cache: [String: Drafts2Snapshot] = [:]
  private var latestRevisionByPeerKey: [String: Int64] = [:]
  private var pendingAttachmentIdsByPeerKey: [String: Set<String>] = [:]
  private var pendingAttachmentTasks: [String: Task<Void, Never>] = [:]
  private var attachmentObservers: [String: [UUID: Drafts2AttachmentCompletion]] = [:]

  public static let shared = Drafts2()

  public init(database: AppDatabase = .shared) {
    self.database = database
    self.writer = Drafts2PersistenceWriter(database: database)
  }

  public static func nowSeconds() -> Int64 {
    Int64(Date().timeIntervalSince1970)
  }

  public static func normalizedEntities(_ entities: MessageEntities?) -> MessageEntities? {
    guard let entities, !entities.entities.isEmpty else { return nil }
    return entities
  }

  public func cached(peer: Peer) -> Drafts2Snapshot? {
    let peerKey = peer.toString()
    return stateQueue.sync {
      cache[peerKey]
    }
  }

  public func load(peer: Peer, legacyDraftMessage: InlineProtocol.DraftMessage? = nil) -> Drafts2Snapshot? {
    let peerKey = peer.toString()
    let loadedSnapshot = stateQueue.sync { () -> (loaded: Bool, snapshot: Drafts2Snapshot?) in
      (loadedPeerKeys.contains(peerKey), cache[peerKey])
    }
    if loadedSnapshot.loaded {
      return loadedSnapshot.snapshot
    }

    let row = try? database.dbWriter.read { db in
      try Drafts2Row.fetchOne(db, key: peerKey)
    }
    if let row {
      let snapshot = row.snapshot(peer: peer)
      markLoaded(snapshot, peerKey: peerKey)
      return snapshot
    }

    if let legacyDraftMessage,
       !legacyDraftMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let snapshot = Drafts2Snapshot(
        peer: peer,
        text: legacyDraftMessage.text,
        entities: legacyDraftMessage.hasEntities ? legacyDraftMessage.entities : nil,
        revision: nextRevision(peerKey: peerKey),
        updatedAt: Self.nowSeconds()
      )
      markLoaded(snapshot, peerKey: peerKey)
      persist(snapshot)
      return snapshot
    }

    stateQueue.sync {
      loadedPeerKeys.insert(peerKey)
      latestRevisionByPeerKey[peerKey] = latestRevisionByPeerKey[peerKey] ?? 0
    }
    return nil
  }

  @discardableResult
  public func updateText(peer: Peer, text: String) -> Int64 {
    let snapshot = stage(peer: peer) { draft in
      draft.text = text
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        draft.entities = nil
      }
    }
    persist(snapshot)
    return snapshot.revision
  }

  @discardableResult
  public func updateEntities(peer: Peer, entities: MessageEntities?, forRevision revision: Int64) -> Bool {
    let staged = stateQueue.sync { () -> Drafts2Snapshot? in
      let peerKey = peer.toString()
      guard var draft = cache[peerKey], draft.revision == revision else { return nil }
      draft.entities = Self.normalizedEntities(entities)
      draft.updatedAt = Self.nowSeconds()
      cache[peerKey] = draft
      return draft
    }

    guard let staged else { return false }
    persist(staged)
    return true
  }

  @discardableResult
  public func appendAttachment(peer: Peer, media: FileMediaItem, id: String? = nil) -> Drafts2Attachment {
    let attachment = Drafts2Attachment(id: id ?? media.getItemUniqueId(), media: media)
    let snapshot = stage(peer: peer) { draft in
      draft.attachments.removeAll { $0.id == attachment.id }
      draft.attachments.append(attachment)
    }
    persist(snapshot)
    return attachment
  }

  @discardableResult
  public func addImage(
    peer: Peer,
    image: PlatformImage,
    preferredFormat: ImageFormat? = nil,
    onComplete: Drafts2AttachmentCompletion? = nil
  ) -> String {
    startMaterialization(peer: peer, prefix: "pending_photo") {
      .photo(try FileCache.savePhoto(image: image, preferredFormat: preferredFormat))
    } onComplete: { result in
      onComplete?(result)
    }
  }

  @discardableResult
  public func addVideo(
    peer: Peer,
    url: URL,
    thumbnail: PlatformImage? = nil,
    onComplete: Drafts2AttachmentCompletion? = nil
  ) -> String {
    startMaterialization(peer: peer, prefix: "pending_video") {
      .video(try await FileCache.saveVideo(url: url, thumbnail: thumbnail))
    } onComplete: { result in
      onComplete?(result)
    }
  }

  @discardableResult
  public func addFile(
    peer: Peer,
    url: URL,
    onComplete: Drafts2AttachmentCompletion? = nil
  ) -> String {
    startMaterialization(peer: peer, prefix: "pending_document") {
      .document(try FileCache.saveDocument(url: url))
    } onComplete: { result in
      onComplete?(result)
    }
  }

  public func removeAttachment(peer: Peer, id: String) {
    let peerKey = peer.toString()
    let taskKey = Self.pendingTaskKey(peerKey: peerKey, id: id)
    let removedPendingTask = stateQueue.sync { () -> Task<Void, Never>? in
      pendingAttachmentIdsByPeerKey[peerKey]?.remove(id)
      return pendingAttachmentTasks.removeValue(forKey: taskKey)
    }
    removedPendingTask?.cancel()

    let snapshot = stage(peer: peer) { draft in
      draft.attachments.removeAll { $0.id == id }
    }
    persist(snapshot)
  }

  public func clear(peer: Peer) {
    let peerKey = peer.toString()
    let pendingTasks = stateQueue.sync { () -> [Task<Void, Never>] in
      let pendingIds = pendingAttachmentIdsByPeerKey.removeValue(forKey: peerKey) ?? []
      let tasks = pendingIds.compactMap { pendingAttachmentTasks.removeValue(forKey: Self.pendingTaskKey(peerKey: peerKey, id: $0)) }
      loadedPeerKeys.insert(peerKey)
      cache.removeValue(forKey: peerKey)
      latestRevisionByPeerKey[peerKey] = (latestRevisionByPeerKey[peerKey] ?? 0) + 1
      return tasks
    }
    pendingTasks.forEach { $0.cancel() }
    persistEmpty(peerKey: peerKey, revision: latestRevisionByPeerKeyValue(peerKey: peerKey))
  }

  public func prepareSend(peer: Peer) async throws -> Drafts2SendSnapshot {
    let snapshot = load(peer: peer)
    let text = snapshot?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? snapshot?.text : nil
    return Drafts2SendSnapshot(
      text: text,
      entities: snapshot?.entities,
      mediaItems: snapshot?.attachments.map(\.media) ?? []
    )
  }

  public func flushBlocking() {
    writer.flushBlocking()
  }

  public func flush() async {
    await writer.flush()
  }

  public func observeAttachmentResults(
    peer: Peer,
    onComplete: @escaping Drafts2AttachmentCompletion
  ) -> @Sendable () -> Void {
    let peerKey = peer.toString()
    let id = UUID()
    stateQueue.sync {
      attachmentObservers[peerKey, default: [:]][id] = onComplete
    }

    return { [weak self] in
      self?.stateQueue.sync {
        self?.attachmentObservers[peerKey]?.removeValue(forKey: id)
        if self?.attachmentObservers[peerKey]?.isEmpty == true {
          self?.attachmentObservers.removeValue(forKey: peerKey)
        }
      }
    }
  }

  private func startMaterialization(
    peer: Peer,
    prefix: String,
    makeMedia: @escaping @Sendable () async throws -> FileMediaItem,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String {
    let peerKey = peer.toString()
    let pendingId = "\(prefix)_\(UUID().uuidString)"
    let taskKey = Self.pendingTaskKey(peerKey: peerKey, id: pendingId)
    _ = stateQueue.sync {
      pendingAttachmentIdsByPeerKey[peerKey, default: []].insert(pendingId)
    }

    let task = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }

      do {
        let media = try await makeMedia()
        guard !Task.isCancelled else { return }
        guard let attachment = finishMaterialization(peer: peer, pendingId: pendingId, media: media) else {
          let result = Drafts2AttachmentResult.failure(pendingId: pendingId, message: "Attachment was removed")
          emitAttachmentResult(peerKey: peerKey, result: result)
          await MainActor.run { onComplete?(result) }
          return
        }
        let result = Drafts2AttachmentResult.success(pendingId: pendingId, attachment: attachment)
        emitAttachmentResult(peerKey: peerKey, result: result)
        await MainActor.run { onComplete?(result) }
      } catch {
        finishFailedMaterialization(peerKey: peerKey, pendingId: pendingId)
        if !Task.isCancelled {
          log.error("Failed to materialize draft attachment", error: error)
          let result = Drafts2AttachmentResult.failure(pendingId: pendingId, message: error.localizedDescription)
          emitAttachmentResult(peerKey: peerKey, result: result)
          await MainActor.run { onComplete?(result) }
        }
      }
    }

    stateQueue.sync {
      pendingAttachmentTasks[taskKey] = task
    }
    return pendingId
  }

  private func finishMaterialization(peer: Peer, pendingId: String, media: FileMediaItem) -> Drafts2Attachment? {
    let peerKey = peer.toString()
    let taskKey = Self.pendingTaskKey(peerKey: peerKey, id: pendingId)
    let attachment = Drafts2Attachment(id: media.getItemUniqueId(), media: media)
    let snapshot = stateQueue.sync { () -> Drafts2Snapshot? in
      guard pendingAttachmentIdsByPeerKey[peerKey]?.remove(pendingId) != nil else { return nil }
      pendingAttachmentTasks.removeValue(forKey: taskKey)
      var draft = cache[peerKey] ?? Drafts2Snapshot(peer: peer, revision: latestRevisionByPeerKey[peerKey] ?? 0)
      draft.revision = (latestRevisionByPeerKey[peerKey] ?? draft.revision) + 1
      draft.updatedAt = Self.nowSeconds()
      draft.attachments.removeAll { $0.id == pendingId || $0.id == attachment.id }
      draft.attachments.append(attachment)
      cache[peerKey] = draft
      loadedPeerKeys.insert(peerKey)
      latestRevisionByPeerKey[peerKey] = draft.revision
      return draft
    }

    guard let snapshot else { return nil }
    persist(snapshot)
    return attachment
  }

  private func finishFailedMaterialization(peerKey: String, pendingId: String) {
    stateQueue.sync {
      pendingAttachmentIdsByPeerKey[peerKey]?.remove(pendingId)
      pendingAttachmentTasks.removeValue(forKey: Self.pendingTaskKey(peerKey: peerKey, id: pendingId))
    }
  }

  private func emitAttachmentResult(peerKey: String, result: Drafts2AttachmentResult) {
    let observers = stateQueue.sync { () -> [Drafts2AttachmentCompletion] in
      guard let observers = attachmentObservers[peerKey] else { return [] }
      return Array(observers.values)
    }

    for observer in observers {
      Task { @MainActor in
        observer(result)
      }
    }
  }

  private func markLoaded(_ snapshot: Drafts2Snapshot, peerKey: String) {
    stateQueue.sync {
      loadedPeerKeys.insert(peerKey)
      cache[peerKey] = snapshot
      latestRevisionByPeerKey[peerKey] = snapshot.revision
    }
  }

  private func stage(peer: Peer, mutate: (inout Drafts2Snapshot) -> Void) -> Drafts2Snapshot {
    stateQueue.sync {
      let peerKey = peer.toString()
      var draft = cache[peerKey] ?? Drafts2Snapshot(peer: peer, revision: latestRevisionByPeerKey[peerKey] ?? 0)
      mutate(&draft)
      draft.revision = (latestRevisionByPeerKey[peerKey] ?? draft.revision) + 1
      draft.updatedAt = Self.nowSeconds()
      loadedPeerKeys.insert(peerKey)
      latestRevisionByPeerKey[peerKey] = draft.revision
      if draft.isEmpty {
        cache.removeValue(forKey: peerKey)
      } else {
        cache[peerKey] = draft
      }
      return draft
    }
  }

  private func nextRevision(peerKey: String) -> Int64 {
    stateQueue.sync {
      let next = (latestRevisionByPeerKey[peerKey] ?? 0) + 1
      latestRevisionByPeerKey[peerKey] = next
      return next
    }
  }

  private func latestRevisionByPeerKeyValue(peerKey: String) -> Int64 {
    stateQueue.sync {
      latestRevisionByPeerKey[peerKey] ?? 0
    }
  }

  private func persist(_ snapshot: Drafts2Snapshot) {
    let peerKey = snapshot.peer.toString()
    if snapshot.isEmpty {
      persistEmpty(peerKey: peerKey, revision: snapshot.revision)
      return
    }

    let row = Drafts2Row(snapshot: snapshot)
    writer.save(row)
  }

  private func persistEmpty(peerKey: String, revision: Int64) {
    writer.clear(peerKey: peerKey, revision: revision)
  }

  private static func pendingTaskKey(peerKey: String, id: String) -> String {
    "\(peerKey):\(id)"
  }
}

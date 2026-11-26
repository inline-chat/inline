import Combine
import Foundation
import GRDB
import Logger
import os
#if canImport(UIKit)
import UIKit
#endif

/// What a committed write can change in a chat list: specific rows, or (when a write can't be mapped to
/// rows cheaply, such as a message delete) the whole list.
public struct ChatListChange: Sendable, Equatable {
  public var dialogIDs: Set<Int64> = []
  public var requiresFullRefresh = false

  public var isEmpty: Bool { dialogIDs.isEmpty && !requiresFullRefresh }

  mutating func formUnion(_ other: ChatListChange) {
    dialogIDs.formUnion(other.dialogIDs)
    requiresFullRefresh = requiresFullRefresh || other.requiresFullRefresh
  }
}

/// Maps each committed write to the chat list rows it can change.
///
/// `ValueObservation` over the chat list SQL refetches every row (5 ms for 300 chats, more with more
/// chats) whenever any table the query reads changes: an incoming message in any chat, a presence write,
/// a draft keystroke. This observer collects the changed row IDs of the tables the chat list reads (at
/// column granularity, from the compiled SQL's own region), and at commit resolves them to dialog IDs with
/// a few indexed lookups on the writer connection. Tables without a precise mapping, and deletes whose
/// rows can no longer be read, request a full refresh, so the result stays exactly what a full refetch
/// would produce.
final class ChatListChangeRouter: TransactionObserver, @unchecked Sendable {
  private let region: DatabaseRegion
  // Writer-queue state, touched only from TransactionObserver callbacks.
  private var pending: [String: Set<Int64>] = [:]
  private var deletedTables: Set<String> = []
  private var draftDialogByRowID: [Int64: Int64] = [:]
  private let subscribers = OSAllocatedUnfairLock<[UUID: @Sendable (ChatListChange) -> Void]>(initialState: [:])

  /// Tables the router maps to rows. Any other table the chat list reads requests a full refresh.
  static let mappedTables: Set<String> = ["dialog", "chat", "message", "user", "draft2", "translation", "document"]

  init(region: DatabaseRegion) {
    self.region = region
  }

  // MARK: Shared instance per writer

  private struct Registration: @unchecked Sendable {
    weak var writer: AnyObject?
    let router: ChatListChangeRouter
  }

  private static let registry = OSAllocatedUnfairLock<[ObjectIdentifier: Registration]>(initialState: [:])

  /// The writer's router if one is installed. Never touches the database.
  static func existing(for writer: any DatabaseWriter) -> ChatListChangeRouter? {
    let key = ObjectIdentifier(writer as AnyObject)
    return registry.withLock { registry in
      registry[key].flatMap { $0.writer === (writer as AnyObject) ? $0.router : nil }
    }
  }

  /// One router per database writer, installed on first use. Installing waits for the writer (an
  /// observer is added on the writer's queue), so it must not run on the main thread.
  static func shared(for writer: any DatabaseWriter) throws -> ChatListChangeRouter {
    let key = ObjectIdentifier(writer as AnyObject)
    if let existing = existing(for: writer) {
      return existing
    }
    let router = try writer.read { db in
      try ChatListChangeRouter(region: ChatListDatabaseQuery.trackedRegion(db))
    }
    try writer.writeWithoutTransaction { db in
      try router.primeDraftKeys(db)
      db.add(transactionObserver: router, extent: .observerLifetime)
    }
    return registry.withLock { registry in
      if let raced = registry[key], raced.writer === (writer as AnyObject) {
        return raced.router
      }
      registry[key] = Registration(writer: writer as AnyObject, router: router)
      return router
    }
  }

  func subscribe(_ handler: @escaping @Sendable (ChatListChange) -> Void) -> UUID {
    let id = UUID()
    subscribers.withLock { $0[id] = handler }
    return id
  }

  func unsubscribe(_ id: UUID) {
    subscribers.withLock { _ = $0.removeValue(forKey: id) }
  }

  // MARK: TransactionObserver

  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
    region.isModified(byEventsOfKind: eventKind)
  }

  func databaseDidChange(with event: DatabaseEvent) {
    guard region.isModified(by: event) else { return }
    pending[event.tableName, default: []].insert(event.rowID)
    if event.kind == .delete {
      deletedTables.insert(event.tableName)
    }
  }

  func databaseDidRollback(_: Database) {
    pending.removeAll()
    deletedTables.removeAll()
  }

  func databaseDidCommit(_ db: Database) {
    guard !pending.isEmpty else { return }
    let tables = pending
    let deletes = deletedTables
    pending.removeAll()
    deletedTables.removeAll()
    let change: ChatListChange
    do {
      change = try resolve(db, tables: tables, deletes: deletes)
    } catch {
      change = ChatListChange(requiresFullRefresh: true)
    }
    guard !change.isEmpty else { return }
    for handler in subscribers.withLock({ Array($0.values) }) {
      handler(change)
    }
  }

  // MARK: Mapping

  /// Resolves changed rows to the chat list rows they feed. Runs on the writer after commit.
  func resolve(_ db: Database, tables: [String: Set<Int64>], deletes: Set<String>) throws -> ChatListChange {
    var change = ChatListChange()
    for table in tables.keys where !Self.mappedTables.contains(table) {
      change.requiresFullRefresh = true
    }
    // Deleted dialogs, messages, translations and documents can't be traced to their rows after the
    // commit. These deletes are rare (deletions, history clears); a dialog delete also removes the row
    // from any list. Draft deletes resolve through the keys seen earlier; chat and user deletes
    // resolve through the dialog columns that still name them.
    if !deletes.subtracting(["draft2", "chat", "user"]).isEmpty {
      change.requiresFullRefresh = true
    }
    // Drafts first: the rowid map must follow every draft write, full refresh or not.
    if let ids = tables["draft2"] {
      var unresolved = ids
      for row in try Row.fetchAll(
        db.cachedStatement(sql: "SELECT rowid, peerKey FROM draft2 WHERE rowid IN (SELECT value FROM json_each(?))"),
        arguments: [jsonArray(ids)]
      ) {
        let rowID: Int64 = row[0]
        unresolved.remove(rowID)
        if let dialogID = try Self.dialogID(db, draftPeerKey: row[1]) {
          draftDialogByRowID[rowID] = dialogID
          change.dialogIDs.insert(dialogID)
        } else {
          // No dialog shows this draft yet; its dialog's insert refreshes that row. Forget whatever this
          // rowid named before (rowids restart after the tables are cleared).
          draftDialogByRowID.removeValue(forKey: rowID)
        }
      }
      for rowID in unresolved {
        if let dialogID = draftDialogByRowID.removeValue(forKey: rowID) {
          change.dialogIDs.insert(dialogID)
        } else {
          change.requiresFullRefresh = true
        }
      }
    }
    if change.requiresFullRefresh { return change }

    var chatIDs = Set<Int64>()
    if let ids = tables["dialog"] {
      change.dialogIDs.formUnion(ids)
      // A thread row shows its parent DM's peer through the parent chat's dialog, so the dialog's chat
      // also refreshes its child thread rows.
      // A dialog saved before its chat has neither column; it has no child rows to refresh.
      chatIDs.formUnion(try Int64?.fetchAll(
        db.cachedStatement(sql: """
        SELECT COALESCE(chatId, peerThreadId) FROM dialog WHERE id IN (SELECT value FROM json_each(?))
        """),
        arguments: [jsonArray(ids)]
      ).compactMap { $0 })
    }
    if let ids = tables["chat"] {
      chatIDs.formUnion(ids)
    }
    if let ids = tables["message"] {
      // A message feeds the list as a chat's last message or as a thread's parent message.
      change.dialogIDs.formUnion(try Int64.fetchAll(
        db.cachedStatement(sql: """
        SELECT d.id FROM message m
        JOIN chat c ON c.id = m.chatId AND c.lastMsgId = m.messageId
        JOIN dialog d ON COALESCE(d.chatId, d.peerThreadId) = c.id
        WHERE m.globalId IN (SELECT value FROM json_each(?))
        UNION
        SELECT d.id FROM message m
        JOIN chat c ON c.parentChatId = m.chatId AND c.parentMessageId = m.messageId
        JOIN dialog d ON COALESCE(d.chatId, d.peerThreadId) = c.id
        WHERE m.globalId IN (SELECT value FROM json_each(?))
        """),
        arguments: [jsonArray(ids), jsonArray(ids)]
      ))
    }
    if let ids = tables["translation"] {
      change.dialogIDs.formUnion(try Int64.fetchAll(
        db.cachedStatement(sql: """
        SELECT d.id FROM translation t
        JOIN chat c ON c.id = t.chatId AND c.lastMsgId = t.messageId
        JOIN dialog d ON COALESCE(d.chatId, d.peerThreadId) = c.id
        WHERE t.rowid IN (SELECT value FROM json_each(?))
        """),
        arguments: [jsonArray(ids)]
      ))
    }
    if let ids = tables["user"] {
      let users = jsonArray(ids)
      // Peer user of a DM row, last message sender, and the parent DM's peer of a thread row.
      change.dialogIDs.formUnion(try Int64.fetchAll(
        db.cachedStatement(sql: """
        SELECT id FROM dialog WHERE peerUserId IN (SELECT value FROM json_each(?))
        UNION
        SELECT d.id FROM chat c
        JOIN message m ON m.chatId = c.id AND m.messageId = c.lastMsgId
        JOIN dialog d ON COALESCE(d.chatId, d.peerThreadId) = c.id
        WHERE m.fromId IN (SELECT value FROM json_each(?))
        UNION
        SELECT d.id FROM chat parent
        JOIN chat c ON c.parentChatId = parent.id
        JOIN dialog d ON COALESCE(d.chatId, d.peerThreadId) = c.id
        LEFT JOIN dialog pd ON pd.chatId = parent.id
        WHERE COALESCE(pd.peerUserId, parent.peerUserId) IN (SELECT value FROM json_each(?))
        """),
        arguments: [users, users, users]
      ))
    }
    if let ids = tables["document"] {
      change.dialogIDs.formUnion(try Int64.fetchAll(
        db.cachedStatement(sql: """
        SELECT d.id FROM chat c
        JOIN message m ON (m.chatId = c.id AND m.messageId = c.lastMsgId)
          OR (m.chatId = c.parentChatId AND m.messageId = c.parentMessageId)
        JOIN dialog d ON COALESCE(d.chatId, d.peerThreadId) = c.id
        WHERE m.documentId IN (SELECT documentId FROM document WHERE rowid IN (SELECT value FROM json_each(?)))
        """),
        arguments: [jsonArray(ids)]
      ))
    }
    if !chatIDs.isEmpty {
      // Rows of these chats and of their child threads (which show the parent's title and peer).
      change.dialogIDs.formUnion(try Int64.fetchAll(
        db.cachedStatement(sql: """
        SELECT id FROM dialog WHERE COALESCE(chatId, peerThreadId) IN (SELECT value FROM json_each(?))
        UNION
        SELECT d.id FROM chat c
        JOIN dialog d ON COALESCE(d.chatId, d.peerThreadId) = c.id
        WHERE c.parentChatId IN (SELECT value FROM json_each(?))
        """),
        arguments: [jsonArray(chatIDs), jsonArray(chatIDs)]
      ))
    }
    return change
  }

  private func primeDraftKeys(_ db: Database) throws {
    for row in try Row.fetchAll(db, sql: "SELECT rowid, peerKey FROM draft2") {
      if let dialogID = try Self.dialogID(db, draftPeerKey: row[1]) {
        draftDialogByRowID[row[0]] = dialogID
      }
    }
  }

  /// `draft2.peerKey` is `user_<id>` or `thread_<id>`, as the chat list joins it.
  private static func dialogID(_ db: Database, draftPeerKey key: String) throws -> Int64? {
    if key.hasPrefix("user_"), let id = Int64(key.dropFirst(5)) {
      return try Int64.fetchOne(db.cachedStatement(sql: "SELECT id FROM dialog WHERE peerUserId = ?"), arguments: [id])
    }
    if key.hasPrefix("thread_"), let id = Int64(key.dropFirst(7)) {
      return try Int64.fetchOne(
        db.cachedStatement(sql: "SELECT id FROM dialog WHERE peerThreadId = ? AND peerUserId IS NULL"),
        arguments: [id]
      )
    }
    return nil
  }
}

private func jsonArray(_ values: Set<Int64>) -> String {
  "[" + values.map(String.init).joined(separator: ",") + "]"
}

/// A chat list kept current by refetching only the rows each commit can change.
///
/// Produces the same `[ChatListItemSnapshot]` as `ChatListDatabaseQuery.fetchSnapshots` with the same
/// parameters (rows ordered by dialog ID), so callers that used a `ValueObservation` over that query can
/// switch without changing how they consume it.
public final class ChatListLiveQuery: @unchecked Sendable {
  public struct Parameters: Hashable, Sendable {
    public var spaceID: Int64?
    public var includeSpaceChatsInHome: Bool
    public var translationLanguage: String
    public var includePreviewSenderIdentity: Bool
    public var includeOpenedDate: Bool
    public var includeTimestampText: Bool

    public init(
      spaceID: Int64?,
      includeSpaceChatsInHome: Bool,
      translationLanguage: String,
      includePreviewSenderIdentity: Bool = false,
      includeOpenedDate: Bool = true,
      includeTimestampText: Bool = true
    ) {
      self.spaceID = spaceID
      self.includeSpaceChatsInHome = includeSpaceChatsInHome
      self.translationLanguage = translationLanguage
      self.includePreviewSenderIdentity = includePreviewSenderIdentity
      self.includeOpenedDate = includeOpenedDate
      self.includeTimestampText = includeTimestampText
    }
  }

  /// Signpost and slow-refresh breadcrumb for each fetch, so a list keeps the telemetry its
  /// `ValueObservation` query emitted.
  public struct Trace: Sendable {
    public var spanName: StaticString
    public var category: PerformanceTrace.Category
    /// The span's begin message.
    public var label: String
    /// The breadcrumb's `scope` value.
    public var scope: String
    public var slowMessage: String
    public var slowCategory: String
    public var slowThresholdMs: Int

    public init(
      spanName: StaticString,
      category: PerformanceTrace.Category,
      label: String,
      scope: String,
      slowMessage: String,
      slowCategory: String,
      slowThresholdMs: Int = 50
    ) {
      self.spanName = spanName
      self.category = category
      self.label = label
      self.scope = scope
      self.slowMessage = slowMessage
      self.slowCategory = slowCategory
      self.slowThresholdMs = slowThresholdMs
    }
  }

  private let writer: any DatabaseWriter
  private let parameters: Parameters
  private let trace: Trace?
  private let translationLanguage: (@Sendable () -> String)?
  private let queue = DispatchQueue(label: "chat.inline.ChatListLiveQuery", qos: .userInitiated)
  // Queue-confined state.
  private var rows: [Int64: ChatListItemSnapshot] = [:]
  private var emitted: [ChatListItemSnapshot]?
  private var pending = ChatListChange()
  /// Deliver the next snapshot even if it equals the last one: lists group rows into day sections
  /// from the snapshot, and a list that showed an error needs a value to clear it.
  private var forcesNextDelivery = false
  private var isRefreshing = false
  private var refreshScheduled = false
  /// Until a full list is installed (the first read failed, or the query started without one), every
  /// refresh reads every row: an incremental refresh would install only the rows it refetched.
  private var hasFullSnapshot = false
  private var isCancelled = false
  /// Set on cancel, read by deliveries already queued on `deliveryQueue`.
  private let cancelled = OSAllocatedUnfairLock(initialState: false)
  private var subscription: UUID?
  private var router: ChatListChangeRouter?
  private var onChange: (([ChatListItemSnapshot]) -> Void)?
  private var onError: ((any Error) -> Void)?
  private var deliveryQueue: DispatchQueue = .main
  /// Language and local day of the last full fetch.
  private var fetchedLanguage: String
  private var fetchedDay: DateInterval?
  private var failureCount = 0
  private var retryScheduled = false
  private var clockObservers: [any NSObjectProtocol] = []

  /// `translationLanguage`, when given, is read before each refresh in place of the parameter's fixed
  /// value; a change refetches every row, as a `ValueObservation` that read the language per fetch did.
  public init(
    writer: any DatabaseWriter,
    parameters: Parameters,
    trace: Trace? = nil,
    translationLanguage: (@Sendable () -> String)? = nil
  ) {
    self.writer = writer
    self.parameters = parameters
    self.trace = trace
    self.translationLanguage = translationLanguage
    fetchedLanguage = parameters.translationLanguage
  }

  /// Starts observing. With `immediate`, the first value is read and delivered synchronously on the
  /// calling thread (the first frame), like `ValueObservation` with `.immediate` scheduling. Later
  /// values arrive on `deliveryQueue`. The calling thread never waits for the writer.
  public func start(
    immediate: Bool = true,
    deliveryQueue: DispatchQueue = .main,
    onError: @escaping (any Error) -> Void,
    onChange: @escaping ([ChatListItemSnapshot]) -> Void
  ) -> AnyCancellable {
    let router = ChatListChangeRouter.existing(for: writer)
    // Subscribe and read in one block on the queue: a commit that lands during or right after the read
    // is queued behind it, so its incremental refresh merges into the full list and refetches its rows.
    let initial: Result<[ChatListItemSnapshot], any Error>? = queue.sync {
      self.onChange = onChange
      self.onError = onError
      self.deliveryQueue = deliveryQueue
      observeClock()
      if let router { subscribe(router) }
      guard immediate else { return nil }
      do {
        let snapshot = try fetch(nil, language: currentLanguage())
        install(snapshot, deliver: false)
        hasFullSnapshot = true
        return .success(snapshot)
      } catch {
        failureCount = 1
        return .failure(error)
      }
    }
    // Without a router yet, the first refresh installs it on the queue, then refetches every row to
    // catch commits made before it subscribed.
    var needsRefresh = !immediate || router == nil
    switch initial {
      case let .success(snapshot):
        onChange(snapshot)
      case let .failure(error):
        onError(error)
        needsRefresh = true
      case nil:
        break
    }
    if needsRefresh {
      queue.async { self.enqueue(ChatListChange(requiresFullRefresh: true)) }
    }
    // The cancellable keeps the query alive until it is cancelled, like a GRDB observation.
    return AnyCancellable { self.cancel() }
  }

  private func cancel() {
    cancelled.withLock { $0 = true }
    queue.async {
      self.isCancelled = true
      if let id = self.subscription { self.router?.unsubscribe(id) }
      self.subscription = nil
      self.onChange = nil
      self.onError = nil
      for observer in self.clockObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      self.clockObservers = []
    }
  }

  // MARK: Queue-confined

  private func subscribe(_ router: ChatListChangeRouter) {
    self.router = router
    subscription = router.subscribe { [weak self] change in
      self?.queue.async { self?.enqueue(change) }
    }
  }

  private func enqueue(_ change: ChatListChange) {
    guard !isCancelled else { return }
    pending.formUnion(change)
    scheduleRefresh()
  }

  /// One refresh for every change queued before it runs: a burst of commits is read once.
  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    queue.async {
      self.refreshScheduled = false
      self.refreshIfNeeded()
    }
  }

  private func refreshIfNeeded() {
    guard !isCancelled, !isRefreshing, !retryScheduled, !pending.isEmpty else { return }
    isRefreshing = true
    var change = pending
    pending = ChatListChange()
    if !hasFullSnapshot {
      change.requiresFullRefresh = true
    }
    let language = currentLanguage()
    if language != fetchedLanguage {
      change.requiresFullRefresh = true
    }
    // A day change the notifications missed (a suspended app): refetch every row.
    if let fetchedDay, !Self.contains(fetchedDay, Date()) {
      change.requiresFullRefresh = true
      forcesNextDelivery = true
    }
    do {
      if subscription == nil {
        // First use of this writer: installing the router waits for the writer, so it runs here
        // rather than on the thread that started the query.
        subscribe(try ChatListChangeRouter.shared(for: writer))
        change.requiresFullRefresh = true
      }
      if change.requiresFullRefresh {
        install(try fetch(nil, language: language), deliver: true)
        hasFullSnapshot = true
      } else {
        let fresh = try fetch(Array(change.dialogIDs), language: language)
        var next = rows
        for id in change.dialogIDs { next.removeValue(forKey: id) }
        for row in fresh { next[row.dialogID] = row }
        install(next.values.sorted { $0.dialogID < $1.dialogID }, deliver: true)
      }
      failureCount = 0
    } catch {
      // The rows this change names are still stale: keep it, retry with backoff, and deliver the next
      // value even if it is unchanged so a list showing the error recovers. Report only the first
      // failure of a run.
      pending.formUnion(change)
      forcesNextDelivery = true
      failureCount += 1
      if failureCount == 1 {
        let onError = onError
        let cancelled = cancelled
        deliveryQueue.async {
          guard !cancelled.withLock({ $0 }) else { return }
          onError?(error)
        }
      }
      scheduleRetry()
    }
    isRefreshing = false
    if !pending.isEmpty, !retryScheduled {
      scheduleRefresh()
    }
  }

  private func scheduleRetry() {
    guard !retryScheduled else { return }
    retryScheduled = true
    let delay = min(0.25 * pow(2, Double(min(failureCount - 1, 5))), 8)
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      retryScheduled = false
      refreshIfNeeded()
    }
  }

  /// Day sections and timestamp text ("10:42", "Tue", "Nov 3") depend on the current day, time zone and
  /// locale. Incremental refreshes only touch changed rows, so refetch every row and deliver when any of
  /// them changes.
  private func observeClock() {
    var names: [Notification.Name] = [
      .NSCalendarDayChanged,
      .NSSystemTimeZoneDidChange,
      .NSSystemClockDidChange,
      NSLocale.currentLocaleDidChangeNotification,
    ]
    #if canImport(UIKit)
    names.append(UIApplication.significantTimeChangeNotification)
    #endif
    clockObservers = names.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        self?.queue.async { self?.clockDidChange() }
      }
    }
  }

  private func clockDidChange() {
    guard !isCancelled else { return }
    forcesNextDelivery = true
    enqueue(ChatListChange(requiresFullRefresh: true))
  }

  private func install(_ snapshot: [ChatListItemSnapshot], deliver: Bool) {
    rows = Dictionary(snapshot.map { ($0.dialogID, $0) }, uniquingKeysWith: { _, last in last })
    let forced = forcesNextDelivery
    forcesNextDelivery = false
    guard forced || snapshot != emitted else { return }
    emitted = snapshot
    if deliver, let onChange {
      let cancelled = cancelled
      deliveryQueue.async {
        // GRDB observations deliver nothing after cancel; neither does this.
        guard !cancelled.withLock({ $0 }) else { return }
        onChange(snapshot)
      }
    }
  }

  private func currentLanguage() -> String {
    translationLanguage?() ?? parameters.translationLanguage
  }

  private static func contains(_ day: DateInterval, _ date: Date) -> Bool {
    date >= day.start && date < day.end
  }

  private func fetch(_ dialogIDs: [Int64]?, language: String) throws -> [ChatListItemSnapshot] {
    let now = Date()
    let snapshots: [ChatListItemSnapshot]
    if let trace {
      let span = PerformanceTrace.begin(trace.spanName, category: trace.category, "\(trace.label)")
      snapshots = try read(dialogIDs, language: language, now: now)
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: now)
      let refetched = dialogIDs.map { " changed=\($0.count)" } ?? ""
      span.end("rows=\(snapshots.count) duration_ms=\(durationMs)\(refetched)")
      PerformanceTrace.slowBreadcrumb(
        trace.slowMessage,
        category: trace.slowCategory,
        durationMs: durationMs,
        thresholdMs: trace.slowThresholdMs,
        data: ["rows": snapshots.count, "scope": trace.scope, "incremental": dialogIDs != nil]
      )
    } else {
      snapshots = try read(dialogIDs, language: language, now: now)
    }
    if dialogIDs == nil {
      fetchedLanguage = language
      fetchedDay = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: now)
    }
    return snapshots
  }

  private func read(_ dialogIDs: [Int64]?, language: String, now: Date) throws -> [ChatListItemSnapshot] {
    try writer.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: parameters.spaceID,
        includeSpaceChatsInHome: parameters.includeSpaceChatsInHome,
        translationLanguage: language,
        includePreviewSenderIdentity: parameters.includePreviewSenderIdentity,
        includeOpenedDate: parameters.includeOpenedDate,
        includeTimestampText: parameters.includeTimestampText,
        now: now,
        onlyDialogIDs: dialogIDs
      )
    }
  }
}

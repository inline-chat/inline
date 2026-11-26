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
/// column granularity, from the compiled SQL's own region), and at commit resolves them to dialog IDs
/// through `ChatListRowIndex`, which it keeps current by reading only the changed rows by primary key, so
/// the writer's cost per commit doesn't grow with the number of chats. Tables without a precise mapping,
/// and deletes whose rows can no longer be read, request a full refresh, so the result stays exactly what
/// a full refetch would produce.
final class ChatListChangeRouter: TransactionObserver, @unchecked Sendable {
  private let region: DatabaseRegion
  // Writer-queue state, touched only from TransactionObserver callbacks.
  private var pending: [String: Set<Int64>] = [:]
  private var deletedTables: Set<String> = []
  private var index = ChatListRowIndex()
  /// Set when keeping the index current failed; the next commit reads it again in full.
  private var needsPrime = false
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
      router.index = try ChatListRowIndex.primed(db)
      db.add(transactionObserver: router, extent: .observerLifetime)
    }
    return registry.withLock { registry in
      if let raced = registry[key], raced.writer === (writer as AnyObject) {
        return raced.router
      }
      // Drop routers whose writer is gone, with their indexes.
      registry = registry.filter { $0.value.writer != nil }
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
    // Only tables the list reads. SQLite also reports the search index's own tables, written by the
    // `message` FTS triggers; GRDB counts such unadvertised events as changes, which would turn every
    // message write into a full refresh.
    guard region.isModified(byEventsOfKind: .delete(tableName: event.tableName)), region.isModified(by: event) else {
      return
    }
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
    var change: ChatListChange
    do {
      if needsPrime {
        // The index read again in full is current; a full refresh covers whatever it missed.
        index = try ChatListRowIndex.primed(db)
        needsPrime = false
        change = ChatListChange(requiresFullRefresh: true)
      } else {
        change = try resolve(db, tables: tables, deletes: deletes)
      }
    } catch {
      needsPrime = true
      change = ChatListChange(requiresFullRefresh: true)
    }
    guard !change.isEmpty else { return }
    for handler in subscribers.withLock({ Array($0.values) }) {
      handler(change)
    }
  }

  // MARK: Mapping

  /// Resolves changed rows to the chat list rows they feed, keeping the index current. Runs on the writer
  /// after commit; reads only the changed rows, by primary key.
  func resolve(_ db: Database, tables: [String: Set<Int64>], deletes: Set<String>) throws -> ChatListChange {
    var change = ChatListChange()
    for table in tables.keys where !Self.mappedTables.contains(table) {
      change.requiresFullRefresh = true
    }
    // Deleted translations and documents can't be traced to their rows after the commit. These deletes
    // are rare (deletions, history clears). Deleted dialogs, chats, users, drafts and messages resolve
    // through the keys the index still holds for them.
    if !deletes.isDisjoint(with: ["translation", "document"]) {
      change.requiresFullRefresh = true
    }

    // The index follows every write first, full refresh or not.
    // Chats whose `parentDialog` (the dialog whose `chatId` is the chat) changed: their reply threads show
    // that dialog's peer.
    var parentDialogChats = Set<Int64>()
    if let ids = tables["dialog"] {
      let fresh = try ChatListRowIndex.fetchDialogKeys(db, ids: ids)
      for id in ids {
        if let old = index.dialogs[id]?.chatID { parentDialogChats.insert(old) }
        if let new = fresh[id]?.chatID { parentDialogChats.insert(new) }
        index.setDialog(id, fresh[id])
      }
      // A deleted dialog's id refetches nothing, which removes its row.
      change.dialogIDs.formUnion(ids)
    }
    let changedChats = tables["chat"] ?? []
    // Chats whose last or anchor message was a changed row: that row may now be gone or have another id.
    var messageLinkedChats = Set<Int64>()
    for rowID in tables["message"] ?? [] {
      messageLinkedChats.formUnion(index.chats(linkedToMessageRow: rowID))
    }
    let messageKeys = try tables["message"].map {
      try ChatListRowIndex.fetchMessageKeys(db, table: "message", rowIDs: $0)
    } ?? []
    var chatsToRead = changedChats.union(messageLinkedChats)
    for key in messageKeys {
      chatsToRead.formUnion(index.chats(readingMessage: key))
    }
    if !chatsToRead.isEmpty {
      let fresh = try ChatListRowIndex.fetchChatKeys(db, ids: chatsToRead)
      for id in chatsToRead { index.setChat(id, fresh[id]) }
    }
    for chatID in parentDialogChats.union(changedChats) {
      index.updateListPeers(of: chatID)
    }
    if let rowIDs = tables["draft2"] {
      let fresh = try ChatListRowIndex.fetchDraftKeys(db, rowIDs: rowIDs)
      for rowID in rowIDs {
        let old = index.draftKeys[rowID]
        let new = fresh[rowID]
        // A batch that clears one draft and saves another can hand the cleared draft's rowid to the new
        // one, so both keys' rows refresh.
        if let old { change.dialogIDs.formUnion(index.rows(ofDraftKey: old)) }
        if let new { change.dialogIDs.formUnion(index.rows(ofDraftKey: new)) }
        if old == nil, new == nil {
          // A rowid the index never saw, now gone.
          change.requiresFullRefresh = true
        }
        index.setDraft(rowID: rowID, key: new)
      }
    }
    if change.requiresFullRefresh { return change }

    // Rows of changed chats, and of reply threads under them (which show the parent's title and peer).
    change.dialogIDs.formUnion(index.rows(ofChats: changedChats))
    change.dialogIDs.formUnion(index.rows(ofThreadsUnder: changedChats.union(parentDialogChats)))
    change.dialogIDs.formUnion(index.rows(ofChats: messageLinkedChats))
    for key in messageKeys {
      change.dialogIDs.formUnion(index.rows(showingMessage: key))
    }
    if let rowIDs = tables["translation"] {
      for key in try ChatListRowIndex.fetchMessageKeys(db, table: "translation", rowIDs: rowIDs) {
        change.dialogIDs.formUnion(index.rows(translating: key))
      }
    }
    for userID in tables["user"] ?? [] {
      change.dialogIDs.formUnion(index.rows(showingUser: userID))
    }
    if let rowIDs = tables["document"] {
      for documentID in try ChatListRowIndex.fetchDocumentIDs(db, rowIDs: rowIDs) {
        change.dialogIDs.formUnion(index.rows(showingDocument: documentID))
      }
    }
    return change
  }

  /// The index as kept at commits so far, for tests comparing it with a full read.
  func currentIndex(_: Database) -> ChatListRowIndex {
    index
  }
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
      queue.async { [weak self] in self?.enqueue(ChatListChange(requiresFullRefresh: true)) }
    }
    // The cancellable keeps the query alive until it is cancelled, like a GRDB observation.
    return AnyCancellable { self.cancel() }
  }

  private func cancel() {
    cancelled.withLock { $0 = true }
    // Weak: a query its owner drops right after cancelling is released on the owner's thread, with the
    // writer it holds, rather than later on this queue (at process exit, that close raced SQLCipher's
    // shutdown). `deinit` then does the same tear-down.
    queue.async { [weak self] in self?.tearDown() }
  }

  private func tearDown() {
    isCancelled = true
    if let id = subscription { router?.unsubscribe(id) }
    subscription = nil
    onChange = nil
    onError = nil
    for observer in clockObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    clockObservers = []
  }

  deinit {
    if let id = subscription { router?.unsubscribe(id) }
    for observer in clockObservers {
      NotificationCenter.default.removeObserver(observer)
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
    queue.async { [weak self] in
      guard let self else { return }
      refreshScheduled = false
      refreshIfNeeded()
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

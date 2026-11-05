import Foundation
import InlineKit
import Observation

/// The message to show for the current match, and the matched text to highlight in it.
public struct InChatSearchSelection: Equatable, Sendable {
  public let messageId: Int64
  public let highlight: String?
}

public struct InChatSearchTiming: Sendable {
  public var localDebounce: Duration
  public var remoteDebounce: Duration

  public init(localDebounce: Duration = .milliseconds(120), remoteDebounce: Duration = .milliseconds(350)) {
    self.localDebounce = localDebounce
    self.remoteDebounce = remoteDebounce
  }

  public static let immediate = InChatSearchTiming(localDebounce: .zero, remoteDebounce: .zero)
}

/// Telegram-style search inside one chat: matches newest first, a current match, and
/// older/newer stepping across pages from the local index and the server.
///
/// Local hits appear first; server hits merge in by message ID. After the first page, each
/// source keeps paging in the background until it runs out, so the total is exact ("3 of 47").
/// Stepping older never skips a hit: when a source that still has pages could hold a message
/// between the current match and the next loaded one, the step waits for that page.
@MainActor
@Observable
public final class InChatSearchViewModel {
  public private(set) var query = ""
  public private(set) var matches: [InChatSearchHit] = []
  public private(set) var currentMessageId: Int64?
  public private(set) var remoteFailed = false

  /// Called when the current match changes so the chat can scroll to it.
  @ObservationIgnored public var onSelect: (@MainActor (InChatSearchSelection) -> Void)?

  /// Hides matches in history the viewer cleared for themselves.
  public var collapsedMaxId: Int64? {
    didSet {
      guard collapsedMaxId != oldValue else { return }
      rebuildMatches()
    }
  }

  public var currentIndex: Int? {
    guard let currentMessageId else { return nil }
    return matches.firstIndex { $0.messageId == currentMessageId }
  }

  public var currentMatch: InChatSearchHit? {
    currentIndex.map { matches[$0] }
  }

  public var isSearching: Bool {
    guard !query.isEmpty else { return false }
    return sources.contains { !$0.loaded && $0.enabled } || pendingStep != nil
  }

  /// More matches may exist past the oldest loaded one.
  public var hasMore: Bool {
    sources.contains { $0.enabled && $0.hasMore }
  }

  /// Results are showing and older pages are still loading, so the total can still grow.
  public var isCounting: Bool {
    !query.isEmpty && !matches.isEmpty && hasMore
  }

  public var canGoOlder: Bool {
    guard !matches.isEmpty else { return false }
    guard let index = currentIndex else { return true }
    return index < matches.count - 1 || hasMore
  }

  public var canGoNewer: Bool {
    guard let index = currentIndex else { return false }
    return index > 0
  }

  /// "3 of 47", "No results", or nil while the query is empty or the first page is loading.
  public var counterText: String? {
    guard !query.isEmpty else { return nil }
    guard !matches.isEmpty else { return isSearching ? nil : "No results" }
    guard let index = currentIndex else { return resultsText }
    return "\(index + 1) of \(matches.count)"
  }

  /// "47 messages", "1 message", "No results", or nil while the query is empty or loading.
  public var resultsText: String? {
    guard !query.isEmpty else { return nil }
    switch matches.count {
      case 0: return isSearching ? nil : "No results"
      case 1: return "1 message"
      default: return "\(matches.count) messages"
    }
  }

  /// The preview line: around the match in the text, or the file name when that is where
  /// the query matched.
  public func snippet(for hit: InChatSearchHit) -> String {
    InChatSearchText.snippet(InChatSearchText.matchedText(of: hit, query: query), query: query)
  }

  @ObservationIgnored private let source: any InChatSearchSource
  @ObservationIgnored private let timing: InChatSearchTiming
  @ObservationIgnored private let pageLimit: Int
  @ObservationIgnored private let countPageLimit: Int
  @ObservationIgnored private var token: UInt64 = 0
  /// The user moved off the newest match, so later pages must not move the selection.
  @ObservationIgnored private var userNavigated = false
  /// `matches` still shows the previous query's results while the new query's first page
  /// loads, so typing never flashes an empty list. They are shown, never stepped through.
  @ObservationIgnored private var showsStaleMatches = false
  private var pendingStep: Step?
  private var sources: [SourceState] = [SourceState(kind: .local), SourceState(kind: .remote)]

  private enum Step { case older }

  private enum Kind { case local, remote }

  private struct SourceState {
    let kind: Kind
    var enabled = false
    var hits: [Int64: InChatSearchHit] = [:]
    var cursor: Int64?
    var hasMore = false
    var loaded = false
    var failed = false
    var task: Task<Void, Never>?

    var isLoading: Bool { task != nil }

    init(kind: Kind) {
      self.kind = kind
    }
  }

  public init(
    source: any InChatSearchSource,
    timing: InChatSearchTiming = InChatSearchTiming(),
    pageLimit: Int = InChatMessageSearch.pageLimit,
    countPageLimit: Int = InChatMessageSearch.countPageLimit
  ) {
    self.source = source
    self.timing = timing
    self.pageLimit = pageLimit
    self.countPageLimit = max(pageLimit, countPageLimit)
  }

  public convenience init(db: AppDatabase, peer: Peer, collapsedMaxId: Int64? = nil) {
    self.init(source: InChatSearchLiveSource(db: db, peer: peer))
    self.collapsedMaxId = collapsedMaxId
  }

  isolated deinit {
    cancelTasks()
  }

  // MARK: Query

  public func setQuery(_ newQuery: String) {
    let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != query else { return }
    query = trimmed
    restart()
  }

  /// Retries the server after a failure, keeping local matches and the current selection.
  public func retry() {
    guard !query.isEmpty, let index = sources.firstIndex(where: { $0.kind == .remote }) else { return }
    sources[index].task?.cancel()
    sources[index] = SourceState(kind: .remote)
    sources[index].enabled = true
    sources[index].hasMore = true
    remoteFailed = false
    rebuildMatches()
    load(sourceAt: index, debounce: .zero)
  }

  public func dispose() {
    token &+= 1
    cancelTasks()
    onSelect = nil
  }

  // MARK: Navigation

  /// Moves to the next older match (Telegram's up arrow), loading pages as needed.
  public func goOlder() {
    guard !query.isEmpty else { return }
    pendingStep = .older
    resolvePendingStep()
  }

  /// Moves to the next newer match (Telegram's down arrow).
  public func goNewer() {
    guard let index = currentIndex, index > 0 else { return }
    pendingStep = nil
    select(matches[index - 1], byUser: true)
  }

  public func select(messageId: Int64) {
    guard !showsStaleMatches, let hit = matches.first(where: { $0.messageId == messageId }) else { return }
    pendingStep = nil
    select(hit, byUser: true)
  }

  // MARK: Loading

  private func restart() {
    token &+= 1
    cancelTasks()
    sources = [SourceState(kind: .local), SourceState(kind: .remote)]
    setCurrentMessageId(nil)
    userNavigated = false
    pendingStep = nil
    if remoteFailed { remoteFailed = false }
    guard !query.isEmpty else {
      showsStaleMatches = false
      if !matches.isEmpty { matches = [] }
      return
    }
    showsStaleMatches = !matches.isEmpty

    for index in sources.indices {
      let enabled = switch sources[index].kind {
        case .local: LocalMessageSearch.isSearchable(query)
        case .remote: true
      }
      sources[index].enabled = enabled
      sources[index].hasMore = enabled
      sources[index].loaded = !enabled
      guard enabled else { continue }
      let debounce = sources[index].kind == .local ? timing.localDebounce : timing.remoteDebounce
      load(sourceAt: index, debounce: debounce)
    }
  }

  private func load(sourceAt index: Int, debounce: Duration) {
    let state = sources[index]
    guard state.enabled, state.hasMore, state.task == nil else { return }
    let token = token
    let query = query
    let cursor = state.cursor
    let kind = state.kind
    let source = source
    // The first page is small so results show fast; later pages are larger to finish the count.
    let limit = cursor == nil ? pageLimit : countPageLimit

    sources[index].task = Task { [weak self] in
      if debounce > .zero {
        try? await Task.sleep(for: debounce)
        guard !Task.isCancelled else { return }
      }
      let result: Result<InChatSearchPage, Error>
      do {
        let page = switch kind {
          case .local: try await source.local(query: query, beforeMessageId: cursor, limit: limit)
          case .remote: try await source.remote(query: query, beforeMessageId: cursor, limit: limit)
        }
        result = .success(page)
      } catch {
        result = .failure(error)
      }
      guard !Task.isCancelled else { return }
      self?.finishLoad(kind: kind, token: token, cursor: cursor, result: result)
    }
  }

  private func finishLoad(kind: Kind, token: UInt64, cursor: Int64?, result: Result<InChatSearchPage, Error>) {
    guard token == self.token, let index = sources.firstIndex(where: { $0.kind == kind }) else { return }
    sources[index].task = nil
    sources[index].loaded = true

    switch result {
      case let .success(page):
        for hit in page.hits {
          sources[index].hits[hit.messageId] = hit
        }
        // A cursor that does not move would request the same page forever.
        let advanced = page.oldestMessageId.map { newCursor in cursor.map { newCursor < $0 } ?? true } ?? false
        sources[index].cursor = page.oldestMessageId ?? cursor
        sources[index].hasMore = page.hasMore && advanced
      case .failure:
        sources[index].hasMore = false
        sources[index].failed = true
        if kind == .remote {
          remoteFailed = true
        }
    }

    let hadSelection = currentMessageId != nil
    // Old results stay up until this query has a match or every source has answered.
    let stillLoading = sources.contains { $0.enabled && !$0.loaded }
    rebuildMatches(keepingStaleIfEmpty: stillLoading)
    if !userNavigated, let newest = matches.first, newest.messageId != currentMessageId {
      // Until the user steps, the selection follows the newest match as pages arrive.
      select(newest, byUser: false)
    }
    if !hadSelection, currentMessageId != nil, pendingStep == .older {
      // An older press made before any match loaded lands on the newest match, not past it.
      pendingStep = nil
      userNavigated = true
    }
    resolvePendingStep()
    // Keep paging until the source runs out so the total is exact.
    load(sourceAt: index, debounce: .zero)
  }

  private func rebuildMatches(keepingStaleIfEmpty: Bool = false) {
    var merged: [Int64: InChatSearchHit] = [:]
    // Local first so the server's copy of a hit wins.
    for state in sources {
      for (id, hit) in state.hits {
        merged[id] = hit
      }
    }
    let floor = collapsedMaxId ?? 0
    let rebuilt = merged.values
      .filter { $0.messageId > floor }
      .sorted { $0.messageId > $1.messageId }
    if showsStaleMatches, rebuilt.isEmpty, keepingStaleIfEmpty { return }
    showsStaleMatches = false
    // Assign only real changes: every assignment re-renders whatever reads `matches`.
    if rebuilt != matches {
      matches = rebuilt
    }
    if let currentMessageId, !matches.contains(where: { $0.messageId == currentMessageId }) {
      setCurrentMessageId(nil)
    }
  }

  private func setCurrentMessageId(_ messageId: Int64?) {
    if currentMessageId != messageId {
      currentMessageId = messageId
    }
  }

  private func resolvePendingStep() {
    // A step waits for the new query's results rather than landing on an old one.
    guard pendingStep == .older, !showsStaleMatches else { return }
    guard let currentMessageId else {
      if let newest = matches.first {
        pendingStep = nil
        select(newest, byUser: true)
      } else if !sources.contains(where: { $0.enabled && $0.hasMore }) {
        pendingStep = nil
      }
      return
    }

    let candidate = matches.first { $0.messageId < currentMessageId }
    let floor = candidate?.messageId ?? 0
    // A source whose cursor is above the candidate may still hold a hit between the two.
    let blocking = sources.indices.filter { index in
      let state = sources[index]
      return state.enabled && state.hasMore && (state.cursor ?? .max) > floor
    }

    guard blocking.isEmpty else {
      for index in blocking {
        load(sourceAt: index, debounce: .zero)
      }
      return
    }

    pendingStep = nil
    if let candidate {
      select(candidate, byUser: true)
    }
  }

  private func select(_ hit: InChatSearchHit, byUser: Bool) {
    if byUser {
      userNavigated = true
    }
    setCurrentMessageId(hit.messageId)
    onSelect?(InChatSearchSelection(
      messageId: hit.messageId,
      highlight: InChatSearchText.highlight(in: hit.text, query: query)
    ))
  }

  private func cancelTasks() {
    for index in sources.indices {
      sources[index].task?.cancel()
      sources[index].task = nil
    }
  }
}

/// Snippet and highlight text for search matches.
public enum InChatSearchText {
  private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  /// The text exactly as it appears in `text` for the first query word found there, so a
  /// case-sensitive highlighter can find it.
  public static func highlight(in text: String, query: String) -> String? {
    for word in words(query) {
      if let range = text.range(of: word, options: options) {
        return String(text[range])
      }
    }
    return nil
  }

  /// The text a hit matched in: its message text, else its file name, else whichever exists.
  public static func matchedText(of hit: InChatSearchHit, query: String) -> String {
    let queryWords = words(query)
    func matches(_ value: String) -> Bool {
      queryWords.contains { value.range(of: $0, options: options) != nil }
    }
    if matches(hit.text) { return hit.text }
    if let fileName = hit.fileName, matches(fileName) { return fileName }
    return hit.text.isEmpty ? (hit.fileName ?? "") : hit.text
  }

  /// One line of text around the first match, with ellipses where it was cut.
  public static func snippet(_ text: String, query: String, radius: Int = 48) -> String {
    let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !line.isEmpty else { return "" }
    let match = words(query).lazy.compactMap { line.range(of: $0, options: options) }.first
    guard let match else {
      return line.count > radius * 2 ? String(line.prefix(radius * 2)) + "…" : line
    }
    let lower = line.index(match.lowerBound, offsetBy: -radius / 2, limitedBy: line.startIndex) ?? line.startIndex
    let upper = line.index(match.upperBound, offsetBy: radius * 2, limitedBy: line.endIndex) ?? line.endIndex
    let prefix = lower == line.startIndex ? "" : "…"
    let suffix = upper == line.endIndex ? "" : "…"
    return prefix + String(line[lower ..< upper]) + suffix
  }

  /// Query words, longest first so the highlight prefers the most specific word.
  static func words(_ query: String) -> [String] {
    query.split(whereSeparator: \.isWhitespace)
      .map(String.init)
      .sorted { $0.count > $1.count }
  }
}

import Foundation
import GRDB
@testable import InlineKit
import Testing

/// Oracle fuzz of the unread opening pipeline: a random server history, a random local cache with
/// persisted coverage, and a random read boundary go through the same calls the macOS preloader
/// and row builder make. The unread line must never be wrong, and must be found whenever the
/// opened window holds it.
///
/// `INLINE_UNREAD_FUZZ_CASES` scales the run; `INLINE_UNREAD_LAB_OUT` writes a JSON report.
@Suite("Unread opening fuzz")
struct ChatUnreadOpeningFuzzTests {
  private static let latestLimit = 60

  @Test @MainActor
  func unreadLineMatchesTheOracle() async throws {
    let env = ProcessInfo.processInfo.environment
    let caseCount = env["INLINE_UNREAD_FUZZ_CASES"].flatMap(Int.init) ?? 160
    var report = Report()

    for seed in 0 ..< UInt64(caseCount) {
      let outcome = try await Self.run(seed: seed)
      report.record(outcome)
      for failure in outcome.failures {
        Issue.record("seed \(seed): \(failure) [\(outcome.summary)]")
      }
    }

    if let path = env["INLINE_UNREAD_LAB_OUT"] {
      let data = try JSONEncoder.pretty.encode(report)
      try data.write(to: URL(fileURLWithPath: path))
    }
    #expect(report.cases == caseCount)
  }

  // MARK: - One case

  struct Outcome: Codable {
    var seed: UInt64
    var maxId: Int64
    var boundary: Int64
    var cacheShape: String
    var path: String
    var oracle: Int64?
    var line: Int64?
    var windowCount: Int
    var keptCount: Int
    var rowsAfterLine: Int?
    var opensAtLiveEnd: Bool
    var failures: [String]

    var summary: String {
      "max=\(maxId) boundary=\(boundary) cache=\(cacheShape) path=\(path) oracle=\(oracle.map(String.init) ?? "nil") line=\(line.map(String.init) ?? "nil") window=\(windowCount) kept=\(keptCount)"
    }
  }

  @MainActor
  static func run(seed: UInt64) async throws -> Outcome {
    var rng = SplitMix64(seed: 0xF00D_0000 &+ seed)
    let server = ServerHistory.random(&rng)
    let boundary = server.randomBoundary(&rng)
    let cache = CacheShape.random(&rng, server: server)

    let database = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123")))
    try await database.dbWriter.write { db in
      try User(id: 1, email: nil, firstName: "Me").insert(db)
      try User(id: 2, email: nil, firstName: "Them").insert(db)
      try Chat(
        id: 1, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Fuzz", spaceId: nil,
        lastMsgId: nil
      ).insert(db)
      try MessageHistoryCoverageStore.invalidate(db, chatId: 1)
      for range in cache.certified {
        try MessageHistoryCoverageStore.subtract(db, chatId: 1, lowerId: range.lowerBound, upperId: range.upperBound)
      }
      for id in cache.localIds {
        try server.save(id, db: db)
      }
    }

    let peer = Peer.thread(id: 1)
    func openingWindow() async throws -> (window: [FullMessage]?, latest: [FullMessage]) {
      try await database.reader.read { db in
        let latest = try Self.latest(db)
        return (try ChatUnreadOpening.localOpeningWindow(db, peer: peer, boundary: boundary, latest: latest), latest)
      }
    }

    var failures: [String] = []
    var (window, latestPage) = try await openingWindow()
    var path = window == nil ? "fetched" : (window == latestPage ? "latest" : "around")
    if window == nil {
      try await database.dbWriter.write { db in try server.applyAroundFetch(anchor: max(1, boundary), db: db) }
      (window, latestPage) = try await openingWindow()
      if window == nil {
        failures.append("an around fetch did not make the opening window local")
        path = "fallback"
      } else {
        path = window == latestPage ? "fetched-latest" : "fetched-around"
      }
    }
    let opened = window ?? latestPage

    let metadata = try await database.reader.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: peer, messages: opened)
    }
    let model = MessagesProgressiveViewModel(
      peer: peer,
      initialState: .init(messages: opened, threadAnchor: .resolved(nil), loadedWindowMetadata: metadata),
      database: database, publisher: MessagesPublisher(database: database), currentUserId: 1
    )
    defer { model.dispose() }
    let line = ChatUnreadOpening.firstUnreadMessageId(in: model.messages, boundary: boundary, of: model)
    let oracle = server.firstUnread(after: boundary)
    let openedIds = Set(opened.map(\.message.messageId))
    let keptIds = model.messages.map(\.message.messageId)

    // Safety: a line is never above the wrong message.
    if let line, line != oracle {
      failures.append("line \(line) but the first unread message is \(oracle.map(String.init) ?? "none")")
    }
    // Liveness: a window chosen for the boundary shows the line whenever it holds that message.
    if path != "fallback", let oracle, openedIds.contains(oracle), line == nil {
      failures.append("window holds first unread \(oracle) but shows no line")
    }
    // The view model keeps every row of a window chosen around the boundary.
    if path == "around" || path == "fetched-around", keptIds.count != opened.count {
      failures.append("view model dropped \(opened.count - keptIds.count) rows of the opening window")
    }
    // A boundary window always holds the read side: the line is not the first kept row unless
    // history starts there.
    if path == "around" || path == "fetched-around", let line, keptIds.first == line,
       server.ids.contains(where: { $0 < line && $0 <= boundary })
    {
      failures.append("boundary window starts at the line with read history above it")
    }

    let rowsAfterLine = line.map { line in keptIds.filter { $0 >= line }.count }
    return Outcome(
      seed: seed, maxId: server.ids.last ?? 0, boundary: boundary, cacheShape: cache.name, path: path,
      oracle: oracle, line: line, windowCount: opened.count, keptCount: keptIds.count,
      rowsAfterLine: rowsAfterLine, opensAtLiveEnd: model.historyCoverage.isAtCertifiedLiveEnd,
      failures: failures
    )
  }

  /// The latest page, read as the macOS preloader reads it.
  nonisolated static func latest(_ db: Database) throws -> [FullMessage] {
    try FullMessage.queryRequest(currentUserId: 1)
      .filter(Column("peerThreadId") == 1)
      .order(Column("date").desc, Column("messageId").desc)
      .limit(latestLimit)
      .fetchAll(db)
      .reversed()
  }

  // MARK: - Report

  struct Report: Codable {
    var cases = 0
    var failures = 0
    var paths: [String: Int] = [:]
    var caches: [String: Int] = [:]
    var withOracle = 0
    var lineShown = 0
    var lineMissedWithOracleOutsideWindow = 0
    var rowsAfterLineHistogram: [String: Int] = [:]
    var failing: [Outcome] = []
    /// No line although a first unread message exists: it lies outside the opened window.
    var missed: [Outcome] = []
    var samples: [Outcome] = []

    mutating func record(_ outcome: Outcome) {
      cases += 1
      paths[outcome.path, default: 0] += 1
      caches[outcome.cacheShape, default: 0] += 1
      if outcome.oracle != nil { withOracle += 1 }
      if outcome.line != nil { lineShown += 1 }
      if outcome.oracle != nil, outcome.line == nil, outcome.failures.isEmpty {
        lineMissedWithOracleOutsideWindow += 1
        if missed.count < 50 { missed.append(outcome) }
      }
      if let rows = outcome.rowsAfterLine {
        let bucket = rows < 10 ? "<10" : rows < 20 ? "10-19" : rows < 40 ? "20-39" : "40+"
        rowsAfterLineHistogram[bucket, default: 0] += 1
      }
      if !outcome.failures.isEmpty {
        failures += 1
        failing.append(outcome)
      } else if samples.count < 40 {
        samples.append(outcome)
      }
    }
  }
}

// MARK: - Models

/// The server's history: ids ascending with deletions, and who sent each message.
private struct ServerHistory {
  var ids: [Int64]
  var outgoing: Set<Int64>

  static func random(_ rng: inout SplitMix64) -> ServerHistory {
    let roll = rng.unit()
    let maxId = Int64(roll < 0.55 ? rng.int(1 ... 300) : roll < 0.9 ? rng.int(300 ... 1_500) : rng.int(1_500 ... 4_000))
    var ids: [Int64] = []
    var outgoing: Set<Int64> = []
    var sendingOwn = rng.chance(0.3)
    for id in Int64(1) ... maxId {
      if rng.chance(0.25) { sendingOwn = rng.chance(0.3) }
      guard !rng.chance(0.04) || id == maxId else { continue }
      ids.append(id)
      if sendingOwn { outgoing.insert(id) }
    }
    return ServerHistory(ids: ids, outgoing: outgoing)
  }

  func randomBoundary(_ rng: inout SplitMix64) -> Int64 {
    let maxId = ids.last ?? 1
    let roll = rng.unit()
    if roll < 0.06 { return 0 }
    if roll < 0.12 { return maxId }
    if roll < 0.45 { return max(0, maxId - Int64(rng.int(0 ... 90))) }
    return Int64(rng.int(1 ... Int(maxId)))
  }

  func firstUnread(after boundary: Int64) -> Int64? {
    ids.first { $0 > boundary && !outgoing.contains($0) }
  }

  func save(_ id: Int64, db: Database) throws {
    let out = outgoing.contains(id)
    var message = Message(
      messageId: id, fromId: out ? 1 : 2, date: Date(timeIntervalSince1970: Double(id)), text: "m\(id)",
      peerUserId: nil, peerThreadId: 1, chatId: 1, out: out
    )
    try message.saveMessage(db)
  }

  /// What `getChatHistory(mode: around, anchor, limit: 88)` returns and proves, as
  /// `GetChatHistoryTransaction.provenCoverages` derives it.
  func applyAroundFetch(anchor: Int64, db: Database) throws {
    let limit = ChatUnreadOpening.windowLimit
    let includesAnchor = ids.contains(anchor)
    let beforeLimit = limit / 2
    let afterLimit = max(0, limit - beforeLimit - (includesAnchor ? 1 : 0))
    let older = Array(ids.filter { $0 < anchor }.suffix(beforeLimit))
    let newer = Array(ids.filter { $0 > anchor }.prefix(afterLimit))
    for id in older + (includesAnchor ? [anchor] : []) + newer {
      try save(id, db: db)
    }
    let lower: Int64 = older.count < beforeLimit ? 1 : (older.first ?? 1)
    let upper: Int64 = newer.count < afterLimit ? MessageHistoryHole.positiveMessageIDMax : (newer.last ?? anchor)
    try MessageHistoryCoverageStore.subtract(db, chatId: 1, lowerId: lower, upperId: upper)
  }
}

/// What the device has: certified ranges hold every server row in them; stale rows outside
/// them come from notifications, search or reply previews.
private struct CacheShape {
  var name: String
  var certified: [ClosedRange<Int64>]
  var localIds: [Int64]

  static func random(_ rng: inout SplitMix64, server: ServerHistory) -> CacheShape {
    let maxId = server.ids.last ?? 1
    let tail = MessageHistoryHole.positiveMessageIDMax
    var certified: [ClosedRange<Int64>]
    let name: String
    let roll = rng.unit()
    if roll < 0.25 {
      name = "complete"
      certified = [1 ... tail]
    } else if roll < 0.5 {
      name = "latest-page"
      let start = server.ids.suffix(60).first ?? 1
      certified = [start ... tail]
    } else if roll < 0.62 {
      name = "empty"
      certified = []
    } else {
      name = "islands"
      certified = []
      for _ in 0 ..< rng.int(1 ... 4) {
        let a = Int64(rng.int(1 ... Int(maxId)))
        let b = min(maxId, a + Int64(rng.int(0 ... 200)))
        certified.append(a ... b)
      }
      if rng.chance(0.6) {
        certified.append(max(1, maxId - Int64(rng.int(0 ... 120))) ... tail)
      }
    }
    let staleRate = rng.chance(0.5) ? 0.08 : 0
    let localIds = server.ids.filter { id in
      certified.contains { $0.contains(id) } || rng.chance(staleRate)
    }
    return CacheShape(name: name, certified: certified, localIds: localIds)
  }
}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

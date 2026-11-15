import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import Auth
@testable import InlineKit

@Suite("Agent runtime info")
struct AgentRuntimeInfoTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private let locale = Locale(identifier: "en_US_POSIX")
  // 2026-11-07 15:00 UTC
  private let now = Date(timeIntervalSince1970: 1_794_063_600)

  private func bot(online: Bool? = nil, lastOnline: Date? = nil) -> InlineKit.User {
    var user = InlineKit.User(id: 7, email: nil, firstName: "Agent")
    user.bot = true
    user.online = online
    user.lastOnline = lastOnline
    return user
  }

  private func runtime(
    _ status: InlineProtocol.AgentRuntimeStatus,
    configure: (inout InlineProtocol.AgentRuntime) -> Void = { _ in }
  ) -> InlineProtocol.AgentRuntime {
    var runtime = InlineProtocol.AgentRuntime()
    runtime.botUserID = 7
    runtime.provider = .codex
    runtime.status = status
    configure(&runtime)
    return runtime
  }

  @Test func readsRuntimeDetails() {
    let info = AgentRuntimeInfo(runtime(.online) {
      $0.machineLabel = "  Studio  "
      $0.executableVersion = "0.52.0"
      $0.bridgeVersion = "0.7.22"
      $0.lastSeen = 1_794_060_000
    })
    #expect(info.status == .online)
    #expect(info.machineLabel == "Studio")
    #expect(info.runtimeTitle == "Codex 0.52.0")
    #expect(info.bridgeVersion == "0.7.22")
    #expect(info.lastSeen == Date(timeIntervalSince1970: 1_794_060_000))
  }

  @Test func emptyFieldsStayNil() {
    let info = AgentRuntimeInfo(runtime(.online) {
      $0.provider = .unspecified
      $0.machineLabel = ""
    })
    #expect(info.machineLabel == nil)
    #expect(info.runtimeTitle == nil)
    #expect(info.bridgeVersion == nil)
  }

  @Test func setupPrefersBridgeText() {
    let withText = AgentRuntimeInfo(runtime(.needsSetup) {
      $0.setup = .with { setup in
        setup.reason = .signIn
        setup.text = "Run codex login"
      }
    })
    #expect(withText.setupSummary == "Run codex login")

    let withReason = AgentRuntimeInfo(runtime(.needsSetup) {
      $0.setup = .with { setup in
        setup.reason = .updateRuntime
        setup.minVersion = "0.50.0"
      }
    })
    #expect(withReason.setupSummary == "Update Codex to 0.50.0 or later.")
    #expect(AgentRuntimeInfo(runtime(.online)).setupSummary == nil)
  }

  @Test func statusPrefersRuntime() {
    let summary = BotStatusSummary.make(
      user: bot(online: true),
      runtime: AgentRuntimeInfo(runtime(.offline) { $0.lastSeen = 1_794_060_000 }),
      now: now, calendar: calendar, locale: locale
    )
    #expect(summary?.title == "Offline")
    #expect(summary?.tone == .offline)
    #expect(summary?.detail?.hasPrefix("Last seen at ") == true)

    let setup = BotStatusSummary.make(user: bot(online: true), runtime: AgentRuntimeInfo(runtime(.needsSetup)))
    #expect(setup?.tone == .attention)
    #expect(setup?.detail == "Finish setup on the bot’s machine.")
  }

  @Test func statusFallsBackToPresence() {
    #expect(BotStatusSummary.make(user: bot(online: true), runtime: nil)?.tone == .online)
    #expect(BotStatusSummary.make(user: bot(online: nil), runtime: nil) == nil)
    let unknownRuntime = AgentRuntimeInfo(runtime(.unspecified))
    #expect(BotStatusSummary.make(user: bot(online: false), runtime: unknownRuntime)?.title == "Offline")
  }

  @Test func viewerAccessInWords() {
    func access(_ ops: Set<InlineProtocol.AgentGrantOperation>, owner: Int64 = 1) -> AgentGrantAccess {
      .init(botUserID: 7, ownerUserID: owner, viewerUserID: 2, operations: ops, revision: 1)
    }
    #expect(access([], owner: 2).viewerAccessSummary == "Owner")
    #expect(access([]).viewerAccessSummary == "No access")
    #expect(access([.invoke, .steer]).viewerAccessSummary == "Can start and steer")
    #expect(access([.invoke, .steer, .configure]).viewerAccessSummary == "Can use and configure")
  }

  @Test("runtime details survive a relaunch from the local projection")
  @MainActor
  func runtimeHydratesFromDatabase() async throws {
    let initial = AuthSnapshot(status: .authenticated(AuthCredentials(userId: 42, token: "test")), didHydrate: true)
    let cache = AuthSnapshotCache(initial: initial)
    let authStore = AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString,
                              readSnapshot: { @Sendable _, _, _ in initial })
    let auth = AuthHandle(cache: cache, store: authStore)
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "test"))
    let database = try AppDatabase(queue)
    let value = runtime(.online) { $0.machineLabel = "Studio" }
    try await queue.write { db in _ = try AgentWorkStateStore.project(runtime: value, db: db) }

    let store = AgentWorkStateStore(database: database, auth: auth)
    #expect(store.runtimeInfo(botUserID: 7)?.machineLabel == "Studio")
    #expect(store.offersOutputMode(botUserID: 7))
  }

  @Test("rows saved before runtime details still decode")
  @MainActor
  func legacyOutputDefaultRowsDecode() async throws {
    let initial = AuthSnapshot(status: .authenticated(AuthCredentials(userId: 42, token: "test")), didHydrate: true)
    let cache = AuthSnapshotCache(initial: initial)
    let authStore = AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString,
                              readSnapshot: { @Sendable _, _, _ in initial })
    let auth = AuthHandle(cache: cache, store: authStore)
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "test"))
    let database = try AppDatabase(queue)
    let legacy = Data(#"{"botUserID":7,"mode":"friendly","isOffline":true}"#.utf8)
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO agentClientState (kind, key, payload) VALUES (?, ?, ?)",
        arguments: ["outputDefault", "7", legacy]
      )
    }

    let store = AgentWorkStateStore(database: database, auth: auth)
    #expect(store.defaultOutputMode(botUserID: 7) == .friendly)
    #expect(store.offlineBotUserIDs.contains(7))
    #expect(store.runtimeInfo(botUserID: 7) == nil)
  }
}

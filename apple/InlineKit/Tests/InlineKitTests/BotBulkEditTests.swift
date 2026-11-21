import Foundation
import InlineProtocol
import Testing
@testable import Auth
@testable import InlineKit
@testable import RealtimeV2

/// Answers `updateAgentSettings` from memory, fails chosen bots and records
/// how many calls ran at once.
private actor SettingsRealtime: InlineRPCRealtime {
  private let failures: [Int64: any Error]
  private(set) var calls: [Int64] = []
  private(set) var inFlight = 0
  private(set) var maxInFlight = 0

  init(failures: [Int64: any Error] = [:]) {
    self.failures = failures
  }

  func callRpcDirect(
    method _: InlineProtocol.Method,
    input: InlineProtocol.RpcCall.OneOf_Input?,
    timeout _: Duration?,
    accountToken _: AuthAccountMutationToken?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    guard case let .updateAgentSettings(request)? = input else { return nil }
    calls.append(request.botUserID)
    inFlight += 1
    maxInFlight = max(maxInFlight, inFlight)
    try? await Task.sleep(for: .milliseconds(20))
    inFlight -= 1
    if let error = failures[request.botUserID] { throw error }
    return .updateAgentSettings(.with {
      $0.settings = .with { settings in
        settings.botUserID = request.botUserID
        if request.hasDefaultOutputMode { settings.defaultOutputMode = request.defaultOutputMode }
        if request.hasOpenToEveryone { settings.openToEveryone = request.openToEveryone }
      }
    })
  }

  func applyUpdatesAndWait(_: [InlineProtocol.Update], accountToken _: AuthAccountMutationToken) async throws {}
}

@MainActor
@Suite("Settings → Bots bulk edit", .serialized)
struct BotBulkEditTests {
  private static func makeAuth() -> AuthHandle {
    let initial = AuthSnapshot(status: .authenticated(AuthCredentials(userId: 42, token: "test")), didHydrate: true)
    let cache = AuthSnapshotCache(initial: initial)
    let store = AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString,
                          readSnapshot: { @Sendable _, _, _ in initial })
    return AuthHandle(cache: cache, store: store)
  }

  private static func stores(_ realtime: SettingsRealtime) -> (AgentWorkStateStore, AgentGrantStore) {
    let auth = makeAuth()
    return (
      AgentWorkStateStore(auth: auth, outputModeRealtime: { realtime }),
      AgentGrantStore(database: nil, auth: auth, realtime: { realtime })
    )
  }

  @Test("output mode: leaves out bots you can't change, skips bots already set, runs 4 at a time, keeps failures per bot")
  func outputMode() async {
    let realtime = SettingsRealtime(failures: [
      23: RealtimeDirectRpcError.timeout,
      26: RealtimeDirectRpcError.rpcError(errorCode: .agentGrantRequired, message: nil, code: 403),
    ])
    let (work, grants) = Self.stores(realtime)
    work.setDefaultOutputMode(.friendly, botUserID: 21)

    let outcome = await BotBulkSettings.apply(
      .outputMode(.friendly),
      to: [21, 22, 23, 24, 25, 26, 27, 28, 22],
      work: work,
      grants: grants,
      canConfigure: { $0 == 28 ? false : nil }
    )

    #expect(outcome.botUserIDs == [21, 22, 23, 24, 25, 26, 27])
    #expect(outcome.results[21] == .unchanged)
    #expect(outcome.results[23] == .failed("Timed out."))
    #expect(outcome.results[26] == .failed("Not yours to change."))
    #expect(outcome.results[23]?.rowNote?.text == "Not updated. Timed out.")
    #expect(outcome.changed == [22, 24, 25, 27])
    #expect(outcome.failed == [23, 26])
    #expect(Set(await realtime.calls) == [22, 23, 24, 25, 26, 27])
    #expect(await realtime.maxInFlight <= BotBulkSettings.concurrency)
    #expect(await realtime.maxInFlight > 1)
    #expect(work.defaultOutputModes[24] == .friendly)
  }

  @Test("a failed change puts back what was stored, including never loaded")
  func rollbackRestoresUnknown() async {
    let realtime = SettingsRealtime(failures: [41: RealtimeDirectRpcError.notConnected, 42: RealtimeDirectRpcError.notConnected])
    let (work, _) = Self.stores(realtime)
    work.setDefaultOutputMode(.friendly, botUserID: 42)

    await #expect(throws: RealtimeDirectRpcError.self) { try await work.updateDefaultOutputMode(.detailed, botUserID: 41) }
    await #expect(throws: RealtimeDirectRpcError.self) { try await work.updateDefaultOutputMode(.detailed, botUserID: 42) }

    // Never loaded stays unknown, so a later "Detailed for all" still sends it.
    #expect(work.defaultOutputModes[41] == nil)
    #expect(work.defaultOutputModes[42] == .friendly)
    #expect(!BotBulkSettings.isAlreadySet(.outputMode(.detailed), botUserID: 41, work: work, grants: AgentGrantStore(database: nil, auth: Self.makeAuth(), realtime: { realtime })))
  }

  @Test("sharing: Everyone notes bots an agent bridge runs; Only me applies to every bot")
  func sharing() async {
    let realtime = SettingsRealtime()
    let (work, grants) = Self.stores(realtime)
    work.apply(runtime: .with { $0.botUserID = 31 })

    let opened = await BotBulkSettings.apply(.openToEveryone(true), to: [31, 32], work: work, grants: grants)
    #expect(opened.results[31] == .cannotShareWithEveryone)
    #expect(opened.results[31]?.rowNote?.text == "Can’t be shared with everyone")
    #expect(opened.results[31]?.rowNote?.isFailure == false)
    #expect(opened.failed.isEmpty)
    #expect(opened.changed == [32])
    #expect(grants.openToEveryoneByBotUserID[32] == true)

    let closed = await BotBulkSettings.apply(.openToEveryone(false), to: [31, 32], work: work, grants: grants)
    #expect(closed.changed == [31, 32])

    let again = await BotBulkSettings.apply(.openToEveryone(false), to: [31, 32], work: work, grants: grants)
    #expect(again.unchanged == [31, 32])
    #expect(again.results.values.allSatisfy { $0.rowNote == nil })
    #expect(await realtime.calls == [32, 31, 32])
  }

  @Test("compact sharing reads Only you, Everyone or You + N")
  func compactSharing() {
    var grants = OwnedAgentGrants(.with { $0.ownerUserID = 42 }, botUserID: 7)
    #expect(grants.compactSharingSummary(openToEveryone: false) == "Only you")
    #expect(grants.compactSharingSummary(openToEveryone: true) == "Everyone")
    grants.apply(userID: 2, operations: [.invoke], revision: 1)
    grants.apply(subject: .space(9), operations: [.invoke], revision: 2)
    #expect(grants.compactSharingSummary(openToEveryone: false) == "You + 2")
  }

  @MainActor
  private final class Attempts {
    var all: [[Int64]] = []
  }

  @Test("editing: unselectable bots stay out, failures stay until fixed, Try Again reruns each failed bot's own change")
  func editModel() async {
    let recorder = Attempts()
    let model = BotBulkEditModel(
      apply: { action, ids in
        recorder.all.append(ids)
        var outcome = BotBulkOutcome(botUserIDs: ids)
        for id in ids {
          outcome.results[id] = (id == 2 && recorder.all.count == 1) || (id == 1 && recorder.all.count == 2)
            ? .failed("Timed out.") : .changed
        }
        if case .openToEveryone(true) = action, ids.contains(3) { outcome.results[3] = .cannotShareWithEveryone }
        return outcome
      },
      isSelectable: { $0 != 4 }
    )
    let listed: [Int64] = [1, 2, 3, 4]

    model.beginEditing()
    model.toggle(4)
    #expect(model.selection.isEmpty)
    model.toggleSelectAll(listed)
    #expect(model.selection == [1, 2, 3])
    #expect(model.isAllSelected(listed))
    model.setSelection([1, 2, 3, 4])
    #expect(model.selection == [1, 2, 3])

    // Bulk: bot 2 fails.
    await model.apply(.outputMode(.friendly), botUserIDs: listed)
    #expect(recorder.all == [[1, 2, 3]])
    #expect(model.selection == [1, 2, 3])
    #expect(model.rowNote(for: 2)?.text == "Not updated. Timed out.")
    #expect(model.rowNote(for: 1) == nil)
    #expect(model.failureHeader == "1 bot wasn’t updated")

    // One row's pop-up, whatever the selection: bot 1 fails too, and bot 4 is never sent.
    await model.apply(.openToEveryone(false), to: [1])
    await model.apply(.outputMode(.detailed), to: [4])
    #expect(recorder.all.count == 2)
    #expect(model.failureHeader == "2 bots weren’t updated")

    // Try Again sends each failed bot the change it missed.
    await model.retryFailed()
    #expect(recorder.all.suffix(2).sorted { $0.first! < $1.first! } == [[1], [2]])
    #expect(model.failureHeader == nil)
    #expect(model.rowNote(for: 2) == nil)
    #expect(!model.isRunning)

    await model.apply(.openToEveryone(true), botUserIDs: listed)
    #expect(model.rowNote(for: 3)?.isFailure == false)
    #expect(model.failureHeader == nil)

    model.toggleSelectAll(listed)
    #expect(model.selection.isEmpty)
    let before = recorder.all.count
    await model.apply(.outputMode(.detailed), botUserIDs: listed)
    #expect(recorder.all.count == before)

    model.endEditing()
    #expect(!model.isEditing && model.selection.isEmpty && model.results.isEmpty)
  }
}

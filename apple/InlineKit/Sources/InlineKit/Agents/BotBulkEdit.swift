import Foundation
import InlineProtocol
import Observation
import RealtimeV2

/// A change Settings → Bots applies to every selected bot.
public enum BotBulkAction: Equatable, Hashable, Sendable {
  case outputMode(AgentThreadOutputMode)
  /// Everyone (true) or Only me (false). Only me keeps the people and spaces
  /// added to a bot one by one, like `inline bots access close`.
  case openToEveryone(Bool)

  public var title: String {
    switch self {
      case let .outputMode(mode): mode.title
      case .openToEveryone(true): String(localized: "Everyone")
      case .openToEveryone(false): String(localized: "Only me")
    }
  }
}

/// What one bulk change did to one bot.
public enum BotBulkResult: Equatable, Hashable, Sendable {
  case changed
  /// Already set, so nothing was sent.
  case unchanged
  /// Everyone, for a bot an agent bridge runs: the server refuses, since the
  /// bridge answers only its owner and access list. A note, not a failure.
  case cannotShareWithEveryone
  /// Not updated, with a short reason.
  case failed(String)

  /// The line under the bot's row, if any. Success shows nothing.
  public var rowNote: (text: String, isFailure: Bool)? {
    switch self {
      case .changed, .unchanged: nil
      case .cannotShareWithEveryone: (String(localized: "Can’t be shared with everyone"), false)
      case let .failed(reason): (String(localized: "Not updated. \(reason)"), true)
    }
  }
}

/// One bulk change across several bots, in the order they were listed.
public struct BotBulkOutcome: Equatable, Sendable {
  public var botUserIDs: [Int64]
  public var results: [Int64: BotBulkResult]

  public init(botUserIDs: [Int64] = [], results: [Int64: BotBulkResult] = [:]) {
    self.botUserIDs = botUserIDs
    self.results = results
  }

  public var changed: [Int64] { ids { $0 == .changed } }
  public var unchanged: [Int64] { ids { $0 == .unchanged } }
  public var failed: [Int64] { ids { if case .failed = $0 { true } else { false } } }

  private func ids(_ matches: (BotBulkResult) -> Bool) -> [Int64] {
    botUserIDs.filter { results[$0].map(matches) == true }
  }
}

/// Settings for many bots at once, sent bot by bot through the calls each
/// bot's own settings use, a few at a time. The server has no batch call.
@MainActor
public enum BotBulkSettings {
  static let concurrency = 4

  /// Whether the viewer may change the bot's settings: its owner or an admin.
  /// Nil while unknown; the server decides then.
  public static func canConfigure(botUserID: Int64, grants: AgentGrantStore = .shared) -> Bool? {
    grants.access(botUserID: botUserID)?.canManage
  }

  /// Applies `action` to `botUserIDs` (in that order) and reports each bot.
  /// Bots known not to be the viewer's to change are left out entirely.
  /// Bots already set (when their setting has loaded) aren't sent.
  public static func apply(
    _ action: BotBulkAction,
    to botUserIDs: [Int64],
    work: AgentWorkStateStore = .shared,
    grants: AgentGrantStore = .shared,
    canConfigure: ((Int64) -> Bool?)? = nil
  ) async -> BotBulkOutcome {
    let canConfigure = canConfigure ?? { Self.canConfigure(botUserID: $0, grants: grants) }
    var outcome = BotBulkOutcome(botUserIDs: unique(botUserIDs).filter { canConfigure($0) != false })
    var pending: [Int64] = []
    for id in outcome.botUserIDs {
      if isAlreadySet(action, botUserID: id, work: work, grants: grants) {
        outcome.results[id] = .unchanged
      } else if case .openToEveryone(true) = action, work.runtimeBotUserIDs.contains(id) {
        outcome.results[id] = .cannotShareWithEveryone
      } else {
        pending.append(id)
      }
    }
    let failures = await run(pending) { id in
      switch action {
        case let .outputMode(mode): try await work.updateDefaultOutputMode(mode, botUserID: id)
        case let .openToEveryone(open): try await grants.setOpenToEveryone(open, botUserID: id)
      }
    }
    for id in pending {
      outcome.results[id] = failures[id].map(BotBulkResult.failed) ?? .changed
    }
    return outcome
  }

  /// Only a loaded value counts: the Detailed shown before a load is a guess.
  static func isAlreadySet(
    _ action: BotBulkAction,
    botUserID: Int64,
    work: AgentWorkStateStore,
    grants: AgentGrantStore
  ) -> Bool {
    switch action {
      case let .outputMode(mode): work.defaultOutputModes[botUserID] == mode
      case let .openToEveryone(open): grants.openToEveryoneByBotUserID[botUserID] == open
    }
  }

  /// Runs `operation` for each id, `concurrency` at a time; returns each
  /// failed id with its short reason.
  static func run(
    _ ids: [Int64],
    operation: @escaping @MainActor (Int64) async throws -> Void
  ) async -> [Int64: String] {
    var failures: [Int64: String] = [:]
    var start = 0
    while start < ids.count {
      let batch = ids[start ..< min(start + concurrency, ids.count)]
      start += concurrency
      let tasks = batch.map { id in
        Task { @MainActor in
          do {
            try await operation(id)
            return (id, String?.none)
          } catch {
            return (id, shortReason(error))
          }
        }
      }
      for task in tasks {
        let (id, reason) = await task.value
        if let reason { failures[id] = reason }
      }
    }
    return failures
  }

  /// A few words for a row: "Timed out.", "You’re offline.", or the server's own message.
  static func shortReason(_ error: Error) -> String {
    switch error as? RealtimeDirectRpcError {
      case .timeout?: return String(localized: "Timed out.")
      case .notConnected?: return String(localized: "You’re offline.")
      case .notAuthorized?: return String(localized: "Sign in again.")
      case .capacityExceeded?: return String(localized: "Inline is busy.")
      case .commitOutcomeUnknown?: return String(localized: "Refresh to check.")
      case let .rpcError(code, message, _)?:
        if code == .agentGrantRequired { return String(localized: "Not yours to change.") }
        if let message, !message.isEmpty { return message.hasSuffix(".") ? message : message + "." }
        return String(localized: "Something went wrong.")
      case .unknown?, nil:
        if error is CancellationError { return String(localized: "Cancelled.") }
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty { return described }
        return String(localized: "Something went wrong.")
    }
  }

  private static func unique(_ ids: [Int64]) -> [Int64] {
    var seen: Set<Int64> = []
    return ids.filter { $0 > 0 && seen.insert($0).inserted }
  }
}

/// Settings → Bots editing (the iOS edit mode, the macOS Edit Bots sheet):
/// which bots are selected, and which ones a change didn't update. Success
/// shows nothing: rows update in place. The selection stays after a change.
@MainActor
@Observable
public final class BotBulkEditModel {
  public var isEditing = false
  public private(set) var selection: Set<Int64> = []
  /// Bots with a change in flight.
  public private(set) var busyBots: Set<Int64> = []
  /// The latest result per bot since editing began.
  public private(set) var results: [Int64: BotBulkResult] = [:]

  /// The change each failed bot didn't get, for Try Again.
  @ObservationIgnored private var failedActions: [Int64: BotBulkAction] = [:]
  @ObservationIgnored private let applyAction: @MainActor (BotBulkAction, [Int64]) async -> BotBulkOutcome
  @ObservationIgnored private let selectable: @MainActor (Int64) -> Bool

  public convenience init() {
    self.init(
      apply: { action, ids in await BotBulkSettings.apply(action, to: ids) },
      isSelectable: { BotBulkSettings.canConfigure(botUserID: $0) != false }
    )
  }

  init(
    apply: @escaping @MainActor (BotBulkAction, [Int64]) async -> BotBulkOutcome,
    isSelectable: @escaping @MainActor (Int64) -> Bool = { _ in true }
  ) {
    applyAction = apply
    selectable = isSelectable
  }

  public var isRunning: Bool { !busyBots.isEmpty }

  /// False for a bot the viewer can't change: its row is dimmed and reads
  /// "Not yours to change". Unknown counts as selectable.
  public func isSelectable(_ botUserID: Int64) -> Bool {
    selectable(botUserID)
  }

  public func beginEditing() {
    isEditing = true
  }

  /// Leaves editing and forgets the selection and the results.
  public func endEditing() {
    isEditing = false
    selection = []
    results = [:]
    failedActions = [:]
  }

  public func toggle(_ botUserID: Int64) {
    if selection.contains(botUserID) {
      selection.remove(botUserID)
    } else if isSelectable(botUserID) {
      selection.insert(botUserID)
    }
  }

  /// For list views that bind selection directly; unselectable bots are dropped.
  public func setSelection(_ botUserIDs: Set<Int64>) {
    let next = botUserIDs.filter(isSelectable)
    if next != selection { selection = next }
  }

  public func isAllSelected(_ botUserIDs: [Int64]) -> Bool {
    let candidates = botUserIDs.filter(isSelectable)
    return !candidates.isEmpty && candidates.allSatisfy(selection.contains)
  }

  /// Select All, or Deselect All when every selectable bot is selected.
  public func toggleSelectAll(_ botUserIDs: [Int64]) {
    selection = isAllSelected(botUserIDs) ? [] : Set(botUserIDs.filter(isSelectable))
  }

  /// The selected bots in list order, dropping any that left the list.
  public func selectedBots(in botUserIDs: [Int64]) -> [Int64] {
    botUserIDs.filter(selection.contains)
  }

  /// Applies `action` to the selected bots, in list order.
  public func apply(_ action: BotBulkAction, botUserIDs: [Int64]) async {
    await run(action, on: selectedBots(in: botUserIDs))
  }

  /// Applies `action` to these bots (in this order) whatever the selection:
  /// one row's pop-up, or a context menu on a selection.
  public func apply(_ action: BotBulkAction, to botUserIDs: [Int64]) async {
    await run(action, on: botUserIDs.filter(isSelectable))
  }

  /// The line under a bot's row, or its alert's tooltip: a failure or a note.
  public func rowNote(for botUserID: Int64) -> (text: String, isFailure: Bool)? {
    results[botUserID]?.rowNote
  }

  /// Bots a change didn't update since editing began, in id order.
  public var failedBots: [Int64] {
    failedActions.keys.sorted()
  }

  /// "1 bot wasn’t updated" / "3 bots weren’t updated"; nil when none failed.
  public var failureHeader: String? {
    switch failedActions.count {
      case 0: nil
      case 1: String(localized: "1 bot wasn’t updated")
      case let count: String(localized: "\(count) bots weren’t updated")
    }
  }

  /// Runs each failed bot's change again.
  public func retryFailed() async {
    let byAction = Dictionary(grouping: failedBots) { failedActions[$0]! }
    for (action, ids) in byAction.sorted(by: { $0.value.first ?? 0 < $1.value.first ?? 0 }) {
      await run(action, on: ids)
    }
  }

  private func run(_ action: BotBulkAction, on targets: [Int64]) async {
    let targets = targets.filter { !busyBots.contains($0) }
    guard !targets.isEmpty else { return }
    busyBots.formUnion(targets)
    let outcome = await applyAction(action, targets)
    busyBots.subtract(targets)
    for id in targets {
      guard let result = outcome.results[id] else { continue }
      results[id] = result
      if case .failed = result { failedActions[id] = action } else { failedActions[id] = nil }
    }
  }
}

/// A bot's one-line subtitle in Settings → Bots: "Friendly · Only you",
/// "Detailed · You + 1", or just the sharing for bots without an output mode.
@MainActor
public enum BotSettingsSubtitle {
  public static func text(
    botUserID: Int64,
    work: AgentWorkStateStore = .shared,
    grants: AgentGrantStore = .shared
  ) -> String? {
    var parts: [String] = []
    if work.offersOutputMode(botUserID: botUserID) {
      parts.append(work.defaultOutputMode(botUserID: botUserID).title)
    }
    if let owned = grants.ownedGrants(botUserID: botUserID) {
      parts.append(owned.compactSharingSummary(openToEveryone: grants.openToEveryoneByBotUserID[botUserID] == true))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Replaces the subtitle for a bot the viewer can't change.
  public static var notYours: String { String(localized: "Not yours to change") }
}

import Auth
import Foundation
import InlineCompat
import Logger
import Observation
import RealtimeV2

/// Finds people to give a bot access to: local matches first, then the
/// server's user search. Excludes bots, the viewer and people who already
/// have access.
@MainActor
public final class BotAccessPeopleSearch: CompatObservable {
  public let observationRegistrar = CompatObservationRegistrar()
  @Tracked public var query = "" {
    didSet { if query != oldValue { search() } }
  }

  @Tracked public private(set) var results: [UserInfo] = []
  @Tracked public private(set) var isSearching = false

  /// People already listed, kept out of the results.
  public var excludedUserIDs: Set<Int64> = []

  private let botUserID: Int64
  private let realtime: RealtimeV2
  private let database: AppDatabase
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private let log = Log.scoped("BotAccessPeopleSearch")

  public init(botUserID: Int64, realtime: RealtimeV2, database: AppDatabase = .shared) {
    self.botUserID = botUserID
    self.realtime = realtime
    self.database = database
  }

  public func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
    isSearching = false
  }

  private func search() {
    cancel()
    let generation = generation
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      results = []
      return
    }

    var excluded = excludedUserIDs
    excluded.insert(botUserID)
    if let viewerID = Auth.shared.getCurrentUserId() { excluded.insert(viewerID) }
    let remoteEligible = InviteDirectory.remoteSearchIsEligible(query: query)
    isSearching = remoteEligible
    let database = database
    let realtime = realtime

    task = Task { [weak self] in
      do {
        let local = try await InviteDirectory.localUsers(query: query, database: database)
        guard let self, self.generation == generation else { return }
        let people = Self.people(InviteDirectory.mergedUsers(local: local, remote: [], excluding: excluded))
        results = people
        guard remoteEligible else { return }

        // A short pause so typing does not search every keystroke remotely.
        try await Task.sleep(for: .milliseconds(250))
        let remote = try await InviteDirectory.remoteUsers(query: query, realtime: realtime, database: database)
        guard self.generation == generation else { return }
        results = Self.people(InviteDirectory.mergedUsers(local: local, remote: remote, excluding: excluded))
        isSearching = false
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.generation == generation else { return }
        log.error("Failed to search people for bot access", error: error)
        isSearching = false
      }
    }
  }

  private static func people(_ users: [UserInfo]) -> [UserInfo] {
    users.filter { !$0.user.bot && $0.user.pendingSetup != true }
  }
}

@available(iOS 17.0, macOS 14.0, *)
extension BotAccessPeopleSearch: Observable {}

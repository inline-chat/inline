import Auth
import Combine
import Foundation
import GRDB
import Logger

/// Backs the people list of a privacy exception: who is in it, plus DM
/// partners and search results to add.
@MainActor
public final class PrivacyPeoplePickerModel: ObservableObject {
  @Published public private(set) var selectedUsers: [UserInfo] = []
  @Published public private(set) var candidates: [UserInfo] = []
  @Published public private(set) var isSearching = false
  @Published public var searchText = "" {
    didSet { scheduleSearch() }
  }

  /// Stored IDs this device has no user row for; kept so a save never drops them.
  @Published public private(set) var unresolvedIDs: [Int64] = []

  private let database: AppDatabase
  private var recentPeers: [UserInfo] = []
  private var searchTask: Task<Void, Never>?

  public init(database: AppDatabase = .shared) {
    self.database = database
  }

  /// The list to save, in display order.
  public var selectedIDs: [Int64] {
    selectedUsers.map(\.id) + unresolvedIDs
  }

  /// Resolves stored IDs to people, keeping the list order.
  public func load(selectedIDs: [Int64]) async {
    let currentUserID = Auth.shared.getCurrentUserId()
    do {
      let (selected, recent) = try await database.dbWriter.read { db in
        let selected = try User.userInfoQuery()
          .filter(selectedIDs.contains(User.Columns.id))
          .fetchAll(db)
        let recent = try User.userInfoQuery()
          .filter(User.Columns.id != currentUserID)
          .filter(sql: """
          COALESCE(bot, 0) = 0
          AND "user".id IN (SELECT peerUserId FROM chat WHERE peerUserId IS NOT NULL)
          """)
          .limit(30)
          .fetchAll(db)
        return (selected, recent)
      }
      let byID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
      selectedUsers = selectedIDs.compactMap { byID[$0] }
      unresolvedIDs = selectedIDs.filter { byID[$0] == nil }
      recentPeers = recent.sorted { $0.user.displayName.localizedCompare($1.user.displayName) == .orderedAscending }
      refreshCandidates(local: recentPeers, remote: [])
    } catch {
      Log.shared.error("Failed to load privacy exception people", error: error)
    }
  }

  public func add(_ userInfo: UserInfo) {
    guard !selectedUsers.contains(where: { $0.id == userInfo.id }) else { return }
    selectedUsers.append(userInfo)
    refreshCandidates(local: candidates, remote: [])
  }

  public func remove(id: Int64) {
    selectedUsers.removeAll { $0.id == id }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty { refreshCandidates(local: recentPeers, remote: []) }
  }

  private func scheduleSearch() {
    searchTask?.cancel()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      isSearching = false
      refreshCandidates(local: recentPeers, remote: [])
      return
    }

    isSearching = true
    searchTask = Task { [weak self, database] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      let local = (try? await InviteDirectory.localUsers(query: query, database: database)) ?? []
      guard !Task.isCancelled else { return }
      self?.refreshCandidates(local: local, remote: [])
      let remote = (try? await InviteDirectory.remoteUsers(
        query: query,
        realtime: Api.realtime,
        database: database
      )) ?? []
      guard !Task.isCancelled, let self else { return }
      refreshCandidates(local: local, remote: remote.filter { $0.user.bot != true })
      isSearching = false
    }
  }

  private func refreshCandidates(local: [UserInfo], remote: [UserInfo]) {
    var excluded = Set(selectedUsers.map(\.id))
    if let currentUserID = Auth.shared.getCurrentUserId() { excluded.insert(currentUserID) }
    candidates = InviteDirectory.mergedUsers(local: local, remote: remote, excluding: excluded)
  }
}

import Foundation
import GRDB
import Logger
import Observation

/// Edits who can reach a bot the viewer owns: people, whole spaces, and the
/// switch that opens it to everyone. The list itself lives in
/// `AgentGrantStore`; this holds what the screen adds around it (names of
/// spaces and groups, what is in flight, the last failure).
@MainActor
@Observable
public final class BotAccessListModel {
  public let botUserID: Int64

  /// The viewer's spaces, by name: the ones they can share a bot with.
  public private(set) var spaces: [Space] = []
  public private(set) var groupsByID: [Int64: UserGroup] = [:]
  public private(set) var pending: Set<AgentGrantSubject> = []
  public private(set) var isChangingOpen = false
  public var errorMessage: String?

  @ObservationIgnored private let database: AppDatabase
  @ObservationIgnored private let grants: AgentGrantStore
  @ObservationIgnored private let log = Log.scoped("BotAccessListModel")

  public init(botUserID: Int64, database: AppDatabase = .shared, grants: AgentGrantStore? = nil) {
    self.botUserID = botUserID
    self.database = database
    self.grants = grants ?? .shared
  }

  /// Reads the names this screen shows and asks for the current list.
  public func load() async {
    grants.refresh(botUserID: botUserID)
    let loaded = try? await database.reader.read { db -> ([Space], [UserGroup]) in
      (try Space.catalogActive().fetchAll(db), try UserGroup.fetchAll(db))
    }
    guard let (spaces, groups) = loaded else { return }
    self.spaces = spaces.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  public func space(_ id: Int64) -> Space? {
    spaces.first { $0.id == id }
  }

  /// "Design in Acme", or what is known of it.
  public func groupTitle(_ id: Int64) -> String {
    guard let group = groupsByID[id] else { return String(localized: "A group") }
    guard let space = space(group.spaceId) else { return group.name }
    return String(localized: "\(group.name) in \(space.displayName)")
  }

  /// Groups to offer for a search, leaving out the ones already on the list.
  /// Empty without a query: groups are found by name, not browsed.
  public func groupMatches(_ query: String, excluding listed: Set<Int64>) -> [UserGroup] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    return groupsByID.values
      .filter { !listed.contains($0.id) && $0.name.localizedCaseInsensitiveContains(query) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Makes someone on the list an admin, or a regular member again.
  public func setRole(_ role: BotAccessRole, userID: Int64, name: String) {
    let subject = AgentGrantSubject.user(userID)
    guard !pending.contains(subject), let owned = grants.ownedGrants(botUserID: botUserID),
          owned.role(userID: userID) != role
    else { return }
    pending.insert(subject)
    errorMessage = nil
    Task { @MainActor in
      defer { pending.remove(subject) }
      do {
        try await grants.setGrant(
          botUserID: botUserID,
          subject: subject,
          operations: owned.operations(for: role, userID: userID)
        )
      } catch {
        log.error("Failed to change a role on bot \(botUserID)", error: error)
        errorMessage = String(localized: "Couldn’t change \(name)’s role. Try again.")
      }
    }
  }

  /// Spaces to offer for a search, leaving out the ones already on the list.
  public func spaceMatches(_ query: String, excluding listed: Set<Int64>) -> [Space] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return spaces.filter { space in
      !listed.contains(space.id) &&
        (query.isEmpty || space.displayName.localizedCaseInsensitiveContains(query))
    }
  }

  /// Adds or removes one entry. `name` is who the failure message names.
  public func setAccess(_ hasAccess: Bool, subject: AgentGrantSubject, name: String) {
    guard !pending.contains(subject) else { return }
    pending.insert(subject)
    errorMessage = nil
    Task { @MainActor in
      defer { pending.remove(subject) }
      do {
        if hasAccess {
          // A whole space can message the bot; steering stays with people the owner picks.
          let operations: Set = if case .user = subject { .agentAllowlistDefault } else { [.invoke] }
          try await grants.setGrant(botUserID: botUserID, subject: subject, operations: operations)
        } else {
          try await grants.deleteGrant(botUserID: botUserID, subject: subject)
        }
      } catch {
        log.error("Failed to update access on bot \(botUserID)", error: error)
        errorMessage = hasAccess
          ? String(localized: "Couldn’t give \(name) access. Try again.")
          : String(localized: "Couldn’t remove \(name)’s access. Try again.")
      }
    }
  }

  public func setOpenToEveryone(_ open: Bool) {
    guard !isChangingOpen else { return }
    isChangingOpen = true
    errorMessage = nil
    Task { @MainActor in
      defer { isChangingOpen = false }
      do {
        try await grants.setOpenToEveryone(open, botUserID: botUserID)
      } catch {
        log.error("Failed to change who can message bot \(botUserID)", error: error)
        errorMessage = String(localized: "Couldn’t change who can message this bot. Try again.")
      }
    }
  }
}

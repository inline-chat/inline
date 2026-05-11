import Combine
import GRDB
import InlineKit
import Logger
import SwiftUI

@MainActor
final class AddHomeParticipantsViewModel: ObservableObject {
  @Published private(set) var suggestedUsers: [UserInfo] = []
  @Published private(set) var searchResults: [UserInfo] = []
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published var searchText = ""
  @Published var selectedUserIds: Set<Int64> = []

  private let chatId: Int64
  private let excludedUserIds: Set<Int64>
  private let db: AppDatabase
  private var searchTask: Task<Void, Never>?

  init(chatId: Int64, currentUserId: Int64?, currentParticipants: [UserInfo], db: AppDatabase) {
    self.chatId = chatId
    self.db = db

    var excluded = Set(currentParticipants.map { $0.user.id })
    if let currentUserId { excluded.insert(currentUserId) }
    excludedUserIds = excluded
  }

  var canSearch: Bool {
    searchText.count >= 2
  }

  var displayUsers: [UserInfo] {
    canSearch ? searchResults : suggestedUsers
  }

  var filteredUsers: [UserInfo] {
    let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = displayUsers.filter { !excludedUserIds.contains($0.user.id) }

    // Suggested users are already "filtered" by being suggested, but still apply
    // a local filter so typing 1 character narrows them while global search is disabled.
    if !canSearch && normalizedQuery.isEmpty == false {
      return base.filter { userInfo in
        let name = "\(userInfo.user.firstName ?? "") \(userInfo.user.lastName ?? "")"
          .trimmingCharacters(in: .whitespaces)
        let username = userInfo.user.username ?? ""
        let email = userInfo.user.email ?? ""
        return name.localizedCaseInsensitiveContains(normalizedQuery) ||
          username.localizedCaseInsensitiveContains(normalizedQuery) ||
          email.localizedCaseInsensitiveContains(normalizedQuery)
      }
    }

    return base
  }

  var canAddParticipants: Bool {
    !selectedUserIds.isEmpty && !isLoading
  }

  func loadSuggestedUsers() async {
    do {
      let items = try await db.dbWriter.read { db in
        try HomeChatItem.all().fetchAll(db)
      }

      var seen = Set<Int64>()
      // Prefer showing recently-active chats first.
      let sorted = items.sorted { a, b in
        let aTime = a.lastMessage?.message.date.timeIntervalSince1970 ?? a.chat?.date.timeIntervalSince1970 ?? 0
        let bTime = b.lastMessage?.message.date.timeIntervalSince1970 ?? b.chat?.date.timeIntervalSince1970 ?? 0
        return aTime > bTime
      }

      let users = sorted.compactMap(\.user).filter { userInfo in
        guard !excludedUserIds.contains(userInfo.user.id) else { return false }
        if seen.contains(userInfo.user.id) { return false }
        seen.insert(userInfo.user.id)
        return true
      }

      suggestedUsers = users
    } catch {
      Log.shared.error("Failed to load suggested users", error: error)
      // Non-fatal; keep the sheet usable for search.
      suggestedUsers = []
    }
  }

  func search() {
    // Cancel previous search
    searchTask?.cancel()
    errorMessage = nil

    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      searchResults = []
      isLoading = false
      return
    }

    // Keep suggested list interactive for 1-char local filtering.
    guard query.count >= 2 else {
      searchResults = []
      isLoading = false
      return
    }

    isLoading = true

    searchTask = Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }

      do {
        let result = try await ApiClient.shared.searchContacts(query: query)
        guard !Task.isCancelled else { return }

        let ids = result.users.map(\.id)
        if ids.isEmpty {
          searchResults = []
          isLoading = false
          return
        }

        // Save results so avatars and user info are consistent across the app.
        guard !Task.isCancelled else { return }
        try await db.dbWriter.write { db in
          try result.users.forEach { apiUser in
            _ = try apiUser.saveFull(db)
          }
        }

        guard !Task.isCancelled else { return }
        let infos = try await db.dbWriter.read { db in
          // Fetch user infos with photos from the local DB.
          try User
            .filter(ids: ids)
            .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
            .asRequest(of: UserInfo.self)
            .fetchAll(db)
        }
        guard !Task.isCancelled else { return }

        // Preserve server order where possible.
        let byId = Dictionary(uniqueKeysWithValues: infos.map { ($0.user.id, $0) })
        let ordered = ids.compactMap { byId[$0] }

        searchResults = ordered
        isLoading = false
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = error.localizedDescription
        isLoading = false
      }
    }
  }

  func toggleSelection(userId: Int64) {
    if selectedUserIds.contains(userId) {
      selectedUserIds.remove(userId)
    } else {
      selectedUserIds.insert(userId)
    }
  }

  func addSelectedParticipants() async throws {
    isLoading = true
    errorMessage = nil

    do {
      for userId in selectedUserIds {
        try await Api.realtime.send(.addChatParticipant(chatID: chatId, userID: userId))
      }

      selectedUserIds.removeAll()
      isLoading = false
    } catch {
      isLoading = false
      errorMessage = error.localizedDescription
      Log.shared.error("Failed to add participants (home thread)", error: error)
      throw error
    }
  }
}

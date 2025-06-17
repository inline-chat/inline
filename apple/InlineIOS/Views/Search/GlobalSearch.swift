import InlineKit
import SwiftUI

enum GlobalSearchResult: Hashable, Identifiable {
  case users(ApiUser)

  var id: Int64 {
    switch self {
      case let .users(user):
        user.id
    }
  }
}

@MainActor
class GlobalSearch: ObservableObject {
  @Published private(set) var isLoading = false
  @Published private(set) var results = [] as [GlobalSearchResult]
  @Published private(set) var error: Error?

  var canSearch: Bool {
    query.count >= 1
  }

  var hasResults: Bool {
    !results.isEmpty
  }

  private var searchTask: Task<Void, Never>?
  private var query: String

  init(query: String = "") {
    self.query = query
  }

  func updateQuery(_ newQuery: String) {
    query = newQuery
    search()
  }

  func search() {
    // Cancel previous search
    searchTask?.cancel()

    error = nil

    // Clear immediately if user clears search query
    if !canSearch {
      results = []
      isLoading = false
      return
    }

    isLoading = true

    // Create new search task
    searchTask = Task {
      // Debounce for 300ms
      try? await Task.sleep(nanoseconds: 300_000_000)

      // Check if cancelled
      guard !Task.isCancelled else { return }

      do {
        let result = try await ApiClient.shared.searchContacts(query: query)

        // Check if cancelled before updating UI
        guard !Task.isCancelled else { return }

        // Update results on main thread
        self.results = result.users.map { .users($0) }
        self.isLoading = false
      } catch {
        // Check if cancelled before updating error
        guard !Task.isCancelled else { return }

        self.error = error
        self.isLoading = false
      }
    }
  }

  func clear() {
    updateQuery("")
  }
}

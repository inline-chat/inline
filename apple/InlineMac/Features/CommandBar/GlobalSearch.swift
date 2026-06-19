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
    Self.canSearch(query)
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
    guard query != newQuery else { return }
    query = newQuery
    search(query: newQuery)
  }

  func search() {
    search(query: query)
  }

  private func search(query searchQuery: String) {
    // Cancel previous search
    searchTask?.cancel()

    if error != nil {
      error = nil
    }

    // Clear immediately if user clears search query
    if !Self.canSearch(searchQuery) {
      if results.isEmpty == false {
        results = []
      }
      if isLoading {
        isLoading = false
      }
      return
    }

    // Create new search task
    searchTask = Task { @MainActor [weak self] in
      // Debounce for 300ms
      try? await Task.sleep(nanoseconds: 300_000_000)

      // Check if cancelled
      guard !Task.isCancelled, let self else { return }
      if !self.isLoading {
        self.isLoading = true
      }

      do {
        let result = try await ApiClient.shared.searchContacts(query: searchQuery)

        // Check if cancelled before updating UI
        guard !Task.isCancelled, self.query == searchQuery else { return }

        // Update results on main thread
        let newResults: [GlobalSearchResult] = result.users.map { .users($0) }
        if self.results != newResults {
          self.results = newResults
        }
        if self.isLoading {
          self.isLoading = false
        }
      } catch {
        // Check if cancelled before updating error
        guard !Task.isCancelled, self.query == searchQuery else { return }

        self.error = error
        if self.isLoading {
          self.isLoading = false
        }
      }
    }
  }

  func clear() {
    searchTask?.cancel()
    query = ""
    if error != nil {
      error = nil
    }
    if results.isEmpty == false {
      results = []
    }
    if isLoading {
      isLoading = false
    }
  }

  private static func canSearch(_ query: String) -> Bool {
    query.count >= 2
  }
}

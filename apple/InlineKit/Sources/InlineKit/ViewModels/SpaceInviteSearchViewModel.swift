import Auth
import Combine
import GRDB
import Logger
import SwiftUI

@MainActor
public final class SpaceInviteSearchViewModel: ObservableObject {
  @Published public private(set) var results: [ApiUser] = []
  @Published public private(set) var isLoading = false
  @Published public private(set) var error: Error?

  private var searchTask: Task<Void, Never>?
  private var query: String = ""

  public init() {}

  public func search(query: String) async {
    // Cancel previous search
    searchTask?.cancel()

    error = nil
    self.query = query

    // Clear immediately if query is too short
    if query.count < 2 {
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
        self.results = result.users
        self.isLoading = false
      } catch {
        // Check if cancelled before updating error
        guard !Task.isCancelled else { return }

        self.error = error
        self.isLoading = false
      }
    }
  }

  public func clear() {
    searchTask?.cancel()
    query = ""
    results = []
    isLoading = false
    error = nil
  }
}

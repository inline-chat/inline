import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct AddMember: View {
  @State private var animate: Bool = false
  @State private var text = ""
  @State private var searchResults: [User] = []
  @State private var isSearching = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)
  @FormState var formState

  @EnvironmentObject var nav: Navigation
  @Environment(\.appDatabase) var database
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var dataManager: DataManager
  @EnvironmentObject var api: ApiClient

  @Binding var showSheet: Bool
  var spaceId: Int64

  var body: some View {
    NavigationView {
      VStack(alignment: .leading, spacing: 6) {
        if !text.isEmpty {
          searchSection
        }
        Spacer()
      }
      .searchable(text: $text, prompt: "Search by username")
      .onChange(of: text) { _, newValue in
        searchDebouncer.input = newValue
      }
      .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
        guard let value = debouncedValue else { return }
        searchUsers(query: value)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 14)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          HStack {
            Text("Add Member")
              .fontWeight(.medium)
              .font(.body)
            Spacer()
          }
          .frame(maxWidth: .infinity)
        }
      }
    }
  }

  @ViewBuilder
  private var searchSection: some View {
    VStack(alignment: .leading) {
      if isSearching {
        searchLoadingView
      } else if searchResults.isEmpty {
        Text("No users found")
          .foregroundColor(.secondary)
      } else {
        searchResultsList
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var searchLoadingView: some View {
    HStack {
      ProgressView()
      Text("Searching...")
        .foregroundColor(.secondary)
    }
  }

  private var searchResultsList: some View {
    ScrollView {
      LazyVStack {
        ForEach(searchResults) { user in
          searchResultRow(for: user)
        }
      }
    }
  }

  private func searchResultRow(for user: User) -> some View {
    Button {
      addMember(user)
    } label: {
      HStack(alignment: .top) {
        UserAvatar(user: user, size: 36)
          .padding(.trailing, 6)
          .overlay(alignment: .bottomTrailing) {
            Circle()
              .fill(.green)
              .frame(width: 12, height: 12)
              .padding(.leading, -14)
          }

        VStack(alignment: .leading) {
          Text(user.firstName ?? "User")
            .fontWeight(.medium)
            .foregroundColor(.primary)
          if let username = user.username {
            Text("@\(username)")
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }
        .padding(.top, -4)
        Spacer()
      }
      .frame(maxWidth: .infinity)
    }
  }

  private func searchUsers(query: String) {
    guard !query.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    isSearching = true
    Task {
      do {
        let result = try await api.searchContacts(query: query)

        try await database.dbWriter.write { db in
          for apiUser in result.users {
            let user = User(
              id: apiUser.id,
              email: apiUser.email,
              firstName: apiUser.firstName,
              lastName: apiUser.lastName,
              username: apiUser.username
            )
            try user.save(db)
          }
        }

        try await database.reader.read { db in
          searchResults =
            try User
              .filter(Column("username").like("%\(query.lowercased())%"))
              .fetchAll(db)
        }

        await MainActor.run {
          isSearching = false
        }
      } catch {
        Log.shared.error("Error searching users", error: error)
        await MainActor.run {
          searchResults = []
          isSearching = false
        }
      }
    }
  }

  private func addMember(_ user: User) {
    Task {
      do {
        formState.startLoading()
        try await dataManager.addMember(spaceId: spaceId, userId: user.id)
        formState.succeeded()
        showSheet = false
      } catch {
        formState.failed(error: error.localizedDescription)
        Log.shared.error("Failed to add member", error: error)
      }
    }
  }
}

import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct Contacts: View {
  @State private var searchText: String = ""
  @State private var searchResults: [User] = []
  @State private var recentContacts: [User] = []
  @State private var isSearching = false
  @Environment(\.appDatabase) var database
  @EnvironmentObject var dataManager: DataManager
  @EnvironmentObject var nav: Navigation
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var body: some View {
    VStack {
      List {
        if !recentContacts.isEmpty {
          Section("Recent") {
            ForEach(recentContacts) { user in
              ContactRow(user: user) {
                startChat(with: user)
              }
            }
          }
        }

        if !searchText.isEmpty {
          Section("Search Results") {
            if isSearching {
              HStack {
                ProgressView()
                Text("Searching...")
                  .foregroundColor(.secondary)
              }
            } else if searchResults.isEmpty {
              Text("No users found")
                .foregroundColor(.secondary)
            } else {
              ForEach(searchResults) { user in
                ContactRow(user: user) {
                  startChat(with: user)
                }
              }
            }
          }
        }
      }
      .listStyle(.plain)
    }
    .searchable(text: $searchText)
    .onChange(of: searchText) { _, newValue in
      searchDebouncer.input = newValue
    }
    .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
      guard let value = debouncedValue else { return }
      searchUsers(query: value)
    }
    .onAppear {
      loadRecentContacts()
    }
    .navigationTitle("Contacts")
    .toolbarRole(.editor)
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
        let result = try await ApiClient.shared.searchContacts(query: query)

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

  private func loadRecentContacts() {
    Task {
      // TODO: Implement loading recent contacts from messages
      // For now, leaving it empty
      recentContacts = []
    }
  }

  private func startChat(with user: User) {
    Task {
      do {
        if let threadId = try await dataManager.createPrivateChat(peerId: user.id) {
          nav.push(.chat(peer: .user(id: threadId)))
        }
      } catch {
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }
}

struct ContactRow: View {
  let user: User
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top) {
        UserAvatar(
          user: user,
          size: 28
        )
        .padding(.trailing, 4)

        VStack(alignment: .leading) {
          Text(user.firstName ?? "User")
          if let username = user.username {
            Text("@\(username)")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .padding(.top, -4)
      }
    }
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }
}

#Preview {
  NavigationStack {
    Contacts()
      .environment(\.appDatabase, .empty())
  }
}

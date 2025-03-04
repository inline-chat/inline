import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct AddMember: View {
  @State private var animate: Bool = false
  @State private var text = ""
  @State private var searchResults: [UserInfo] = []
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
        searchSection

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
    Group {
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
    List(searchResults) { userInfo in
      searchResultRow(for: userInfo)
        .listRowInsets(EdgeInsets(top: 9, leading: 2, bottom: 2, trailing: 0))
    }
    .listStyle(.plain)
  }

  private func searchResultRow(for userInfo: UserInfo) -> some View {
    Button {
      addMember(userInfo.user)
    } label: {
      HStack(spacing: 9) {
        UserAvatar(userInfo: userInfo, size: 28)
        Text((userInfo.user.firstName ?? "") + " " + (userInfo.user.lastName ?? ""))
          .fontWeight(.medium)
          .foregroundColor(.primary)
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
            try apiUser.saveFull(db)
          }
        }

        try await database.reader.read { db in
          searchResults =
            try User
              .filter(Column("username").like("%\(query.lowercased())%"))
              .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
              .asRequest(of: UserInfo.self)
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

import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct CreateDm: View {
    @Binding var showSheet: Bool
    @State private var username: String = ""
    @State private var searchResults: [User] = []
    @State private var isSearching = false
    @Environment(\.appDatabase) var database
    @EnvironmentObject var dataManager: DataManager
    @EnvironmentObject var nav: Navigation
    @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

    enum Field {
        case search
    }

    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationView {
            VStack {
                TextField("Search username", text: $username)
                    .padding(.horizontal)
                    .fontWeight(.medium)
                    .background(.clear)
                    .font(.body)
                    .focused($focusedField, equals: .search)
                    .onChange(of: username) { _, newValue in
                        searchDebouncer.input = newValue
                    }
                    .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
                        guard let value = debouncedValue else { return }
                        searchUsers(query: value)
                    }
                    .onAppear {
                        focusedField = .search
                    }

                List(searchResults, id: \.id) { user in
                    Button(action: {
                        Task {
                            do {
                                if let threadId = try await dataManager.createPrivateChat(peerId: user.id) {
                                    showSheet = false
                                    nav.push(.chat(peer: .user(id: threadId)))
                                }
                            } catch {
                                Log.shared.error("Failed to create thread", error: error)
                            }
                        }
                    }) {
                        HStack(alignment: .top) {
                            InitialsCircle(
                                firstName: user.firstName ?? "User", lastName: user.lastName ?? nil, size: 28
                            )
                            .padding(.trailing, 4)
                            VStack(alignment: .leading) {
                                Text(user.firstName ?? "User")
                                Text(user.username ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, -4)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(id: "CreateDMToolbar", content: {
                ToolbarItem(id: "NeDMButton", placement: .topBarLeading) {
                    Text("New DM")
                        .fontWeight(.semibold)
                }
            })
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
                let result = try await ApiClient.shared.searchContacts(query: query)

                // Save users to local DB and get results
                try await database.dbWriter.write { db in
                    // Convert API users to local User models and save them
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

                // Read saved users from DB
                try await database.reader.read { db in
                    searchResults = try User.filter(Column("username").like("%\(query.lowercased())%"))
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

    private func selectUser(_ user: User) {
        print("Selected user: \(user)")
        showSheet = false
    }
}

#Preview {
    CreateDm(showSheet: .constant(true))
        .environment(\.appDatabase, .empty())
}

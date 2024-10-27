import GRDB
import InlineKit
import SwiftUI

struct CreateDm: View {
    @Binding var showSheet: Bool
    @State private var username: String = ""
    @State private var searchResults: [User] = []
    @State private var isSearching = false
    @Environment(\.appDatabase) var database

    var body: some View {
        NavigationView {
            VStack {
                TextField("Search username", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                    .onChange(of: username) { newValue in
                        searchUsers(query: newValue)
                    }

                List(searchResults, id: \.id) { user in
                    Button(action: {
                        selectUser(user)
                    }) {
                        HStack {
                            InitialsCircle(name: user.firstName ?? "User")
                            Text(user.firstName ?? "User")
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("New DM")
        }
    }

    private func searchUsers(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        Task {
            do {
                try await database.reader.read { db in
                    searchResults = try User.filter(Column("username").like("%\(query.lowercased())%")).fetchAll(db)
                }

            } catch {
                print("Error searching users: \(error)")
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

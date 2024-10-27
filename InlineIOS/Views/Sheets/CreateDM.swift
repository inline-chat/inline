import GRDB
import InlineKit
import SwiftUI

struct CreateDm: View {
    @Binding var showSheet: Bool
    @State private var username: String = ""
    @State private var searchResults: [User] = []
    @State private var isSearching = false
    @Environment(\.appDatabase) var database
    @EnvironmentObject var dataManager: DataManager
    @EnvironmentObject var nav: Navigation

    var body: some View {
        NavigationView {
            VStack {
                TextField("Search username", text: $username)
                    .padding(.horizontal)
                    .fontWeight(.medium)
                    .background(.clear)
                    .font(.body)
                    .onChange(of: username) { newValue in
                        searchUsers(query: newValue)
                    }
//
                List(searchResults, id: \.id) { user in
                    Button(action: {
                        Task {
                            do {
                                if let threadId = try await dataManager.createThread(spaceId: nil, title: user.username ?? user.firstName ?? user.email ?? user.lastName ?? "User", peerUserId: user.id) {
                                    showSheet = false
                                    nav.push(.chat(id: threadId))
                                }
                            } catch {
                                Log.shared.error("Failed to create thread", error: error)
                            }
                        }
                    }) {
                        HStack {
                            InitialsCircle(name: user.firstName ?? "User", size: 25)
                            Text(user.firstName ?? "User")
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("New DM")
                        .fontWeight(.semibold)
                }
            }
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

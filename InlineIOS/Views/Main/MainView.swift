import InlineKit
import InlineUI
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var nav: Navigation
    @Environment(\.appDatabase) private var database
    @Environment(\.auth) private var auth

    @EnvironmentObject private var api: ApiClient
    @EnvironmentStateObject private var spaceList: SpaceListViewModel
    @EnvironmentStateObject private var home: HomeViewModel
    @State private var user: User? = nil
    @State private var showSheet = false
    @State private var showDmSheet = false

    init() {
        _spaceList = EnvironmentStateObject { env in
            SpaceListViewModel(db: env.appDatabase)
        }
        _home = EnvironmentStateObject { env in
            HomeViewModel(db: env.appDatabase)
        }
    }

    var body: some View {
        VStack {
            if spaceList.spaces.isEmpty && home.chats.isEmpty {
                EmptyStateView(showDmSheet: $showDmSheet, showSheet: $showSheet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if !spaceList.spaces.isEmpty || !home.chats.isEmpty {
                List {
                    if !spaceList.spaces.isEmpty {
                        Section(header: Text("Spaces")) {
                            ForEach(spaceList.spaces.sorted(by: { $0.date > $1.date })) { space in
                                SpaceRowView(space: space)
                                    .onTapGesture {
                                        nav.push(.space(id: space.id))
                                    }
                            }
                        }
                    }

                    if !home.chats.isEmpty {
                        Section(header: Text("Direct Messages")) {
                            ForEach(home.chats.sorted(by: { $0.chat.date > $1.chat.date }), id: \.chat.id) { chat in
                                ChatRowView(item: chat)
                                    .onTapGesture {
                                        nav.push(.chat(id: chat.chat.id))
                                    }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            Task {
                do {
                    try await database.dbWriter.write { db in
                        if let id = auth.getCurrentUserId() {
                            let fetchedUser = try User.fetchOne(db, id: id)
                            if let user = fetchedUser {
                                self.user = user
                            }
                        }
                    }
                } catch {
                    Log.shared.error("Failed to get user", error: error)
                }
            }
        }
        .toolbar(content: {
            ToolbarItem(placement: .topBarLeading) {
                HStack {
                    Image(systemName: "house.fill")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                    Text("Home")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showDmSheet = true
                    } label: {
                        Text("New DM")
                    }

                    Button {
                        showSheet = true
                    } label: {
                        Text("Create Space")
                    }

                    Button("Logout", role: .destructive) {
                        auth.logOut()
                        do {
                            try AppDatabase.clearDB()
                        } catch {
                            Log.shared.error("Failed to delete DB and logout", error: error)
                        }
                        nav.popToRoot()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .tint(Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        })
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .sheet(isPresented: $showSheet) {
            CreateSpace(showSheet: $showSheet)
                .presentationBackground(.thinMaterial)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showDmSheet) {
            CreateDm(showSheet: $showDmSheet)
                .presentationBackground(.thinMaterial)
                .presentationCornerRadius(28)
        }
    }
}

private struct SpaceRowView: View {
    let space: Space

    var body: some View {
        HStack {
            InitialsCircle(name: space.name, size: 25)
                .padding(.trailing, 4)
            Text(space.name)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ChatRowView: View {
    let item: ChatItem

    var body: some View {
        HStack {
            InitialsCircle(name: item.chat.type == .privateChat ? item.peer?.firstName ?? "" : item.chat.title ?? "", size: 26)
                .padding(.trailing, 6)
            Text(item.chat.type == .privateChat ? item.peer?.firstName ?? "" : item.chat.title ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct EmptyStateView: View {
    @Binding var showDmSheet: Bool
    @Binding var showSheet: Bool
    var body: some View {
        VStack {
            Text("🏡")
                .font(.largeTitle)
                .padding(.bottom, 6)

            Text("Home is empty")
                .font(.title2)
                .fontWeight(.bold)
            Text("Create a space or start a DM")
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack {
                Button {
                    showSheet = true
                } label: {
                    Text("Create Space")
                        .foregroundColor(.primary)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Button {
                    showDmSheet = true
                } label: {
                    Text("New DM")
                        .foregroundColor(.primary)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        MainView()
            .environmentObject(Navigation())
            .appDatabase(.emptyWithSpaces())
    }
}

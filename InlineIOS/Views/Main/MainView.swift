import InlineKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var nav: Navigation
    @Environment(\.appDatabase) var database
    @EnvironmentObject var api: ApiClient
    @EnvironmentStateObject var spaceList: SpaceListViewModel
    @State var user: User? = nil
    @State var showSheet: Bool = false

    init() {
        _spaceList = EnvironmentStateObject { env in
            SpaceListViewModel(db: env.appDatabase)
        }
    }

    var body: some View {
        VStack {
            if !spaceList.spaces.isEmpty {
                List(spaceList.spaces.sorted(by: { $0.date > $1.date })) { space in
                    Text(space.name)
                        .onTapGesture {
                            nav.push(.space(id: space.id))
                        }
                }
                .listStyle(.plain)
                .padding(.vertical, 8)
            } else {
                EmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .onAppear {
            Task {
                do {
                    try await database.dbWriter.write { db in
                        if let id = Auth.shared.getCurrentUserId() {
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
//                    Button("Create Space") {
//                        showSheet = true
//                    }
                    Button("Logout", role: .destructive) {
                        Auth.shared.logOut()
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
    }
}

struct EmptyStateView: View {
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

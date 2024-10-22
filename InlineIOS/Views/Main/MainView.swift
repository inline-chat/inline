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
            if let spaces = spaceList.spaces {
                List(spaces.sorted(by: { $0.date > $1.date })) { space in
                    Text(space.name)
                        .onTapGesture {
                            nav.push(.space(id: space.id))
                        }
                }
                .listStyle(.plain)
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            Task {
                do {
                    let result = try await api.getSpaces()

                    if case let .success(response) = result {
                        try await database.dbWriter.write { db in
                            try response.spaces.forEach { space in
                                let space = Space(from: space)
                                try space.save(db)
                            }
                            try response.members.forEach { member in
                                let member = Member(from: member)
                                try member.save(db)
                            }
                        }
                    }
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
                    Circle()
                        .fill(Color(.systemGray6))
                        .frame(width: 28)
                        .overlay(alignment: .center) {
                            Text("🐱")
                                .font(.body)
                        }
                        .padding(.trailing, 6)
                    Text(user?.firstName ?? "Home")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Create Space") {
                        showSheet = true
                    }
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

#Preview {
    NavigationStack {
        MainView()
            .environmentObject(Navigation())
            .appDatabase(.emptyWithSpaces())
    }
}

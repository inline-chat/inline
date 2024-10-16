import InlineKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var nav: Navigation
    @Environment(\.appDatabase) var database

    @State var user: User? = nil

    var body: some View {
        VStack {
            Text("Welcome")
            Text(user?.firstName ?? "")
            Text(user?.email ?? "")

            Button("Logout") {
                Auth.shared.saveToken(nil)
                do {
                    try AppDatabase.clearDB()
                } catch {
                    Log.shared.error("Failed to delete DB and logout", error: error)
                }
                nav.popToRoot()
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
        .navigationBarBackButtonHidden()
    }
}

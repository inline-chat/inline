import InlineKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var nav: Navigation
    @Environment(\.appDatabase) var database
    @EnvironmentObject var userData: UserData

    @State var user: User? = nil

    var body: some View {
        VStack {
            Text("Welcome")
            Text(user?.firstName ?? "")
            Text(user?.email ?? "")

            Button("Logout") {
                Auth.shared.saveToken(nil)
                nav.popToRoot()
            }
        }
        .onAppear {
            print("Appear")
            Task {
                do {
                    // Ensure database is setup
                    try database.setupDatabase()

                    if let userId = userData.userId {
                        let fetchedUser = try await database.dbWriter.read { db in
                            try User.fetchOne(db, id: userId)
                        }
                        self.user = fetchedUser
                        print("fetchedUser \(String(describing: fetchedUser))")
                    }
                } catch {
                    Log.shared.error("Failed to get user", error: error)
                }
            }
        }
        .navigationBarBackButtonHidden()
    }
}

import HeadlineKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var nav: Navigation
    @Environment(\.appDatabase) var database
    @EnvironmentObject var userData: UserData

    @State var user: User? = nil
    var body: some View {
        VStack {
            Text("Welcome")
            Button("Logout") {
                Auth.shared.saveToken(nil)
                nav.popToRoot()
            }
        }
        .task {
            do {
                try await database.dbWriter.write { db in
                    if let userId = userData.userId {
                        let fetchedUser = try User.fetchOne(db, id: userId)
                        self.user = fetchedUser
                        print("fetchedUser \(fetchedUser)")
                    }
                }
            } catch {
                Log.shared.error("Failed to get user", error: error)
            }
        }
        .navigationBarBackButtonHidden()
    }
}

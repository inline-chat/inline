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
                do {
                    
                    try AppDatabase.deleteDB()
                }catch{
                    Log.shared.error("Failed to delete DB and logout", error: error)
                }
                nav.popToRoot()
            }
        }
        .onAppear {}
        .navigationBarBackButtonHidden()
    }
}

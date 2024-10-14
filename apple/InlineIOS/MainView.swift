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
        .onAppear {}
        .navigationBarBackButtonHidden()
    }
}

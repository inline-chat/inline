import HeadlineKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var nav: Navigation

    var body: some View {
        VStack {
            Text("Welcome")
            Button("Logout") {
                Auth.shared.saveToken(nil)
                nav.popToRoot()
            }
        }
        .navigationBarBackButtonHidden()
    }
}

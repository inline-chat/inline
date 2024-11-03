import GRDBQuery
import InlineKit
import InlineUI
import SwiftUI

struct Settings: View {
    @Query(CurrentUser())
    var currentUser: User?
    @Environment(\.auth) var auth

    var body: some View {
        List {
            Section(header: Text("Account")) {
                HStack {
                    InitialsCircle(firstName: currentUser?.firstName ?? "User", lastName: currentUser?.lastName, size: 26)
                        .padding(.trailing, 6)
                    Text(currentUser?.firstName ?? "Dena" + " " + (currentUser?.lastName ?? "Sohrabi"))
                        .font(.body)
                        .fontWeight(.medium)
                }
            }

//            Section(header: Text("Actions")) {
//                Button("Logout", role: .destructive) {
//                    auth.logout()
//                }
//            }
        }
//        .alert("Logout", isPresented: $showLogoutAlert) {
//            Text("Are you sure you want to logout?")
//            Button("Cancel", role: .cancel) {
//                showLogoutAlert = false
//            }
//            Button("Logout", role: .destructive) {
//                auth.logout()
//            }
//        }
    }
}

#Preview("Settings") {
    Settings()
        .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
}

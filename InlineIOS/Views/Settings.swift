import GRDBQuery
import InlineKit
import InlineUI
import SwiftUI

struct Settings: View {
  @Query(CurrentUser())
  var currentUser: User?
  @Environment(\.auth) var auth
  @EnvironmentObject private var ws: WebSocketManager
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var onboardingNav: OnboardingNavigation

  var body: some View {
    List {
      Section(header: Text("Account")) {
        HStack {
          InitialsCircle(
            firstName: currentUser?.firstName ?? "User", lastName: currentUser?.lastName, size: 26
          )
          .padding(.trailing, 6)
          Text(currentUser?.firstName ?? "Not loaded" + " " + (currentUser?.lastName ?? ""))
            .font(.body)
            .fontWeight(.medium)
        }
      }

      Section(header: Text("Actions")) {
        Button("Logout", role: .destructive) {
          // Clear creds
          Auth.shared.logOut()
          
          // Stop WebSocket
          ws.loggedOut()
          
          // Clear database
          try? AppDatabase.loggedOut()
          
          try? AppDatabase.loggedOut()
          
          onboardingNav.push(.welcome)
          
          nav.popToRoot()
        }
      }
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

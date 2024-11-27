import GRDBQuery
import InlineKit
import InlineUI
import SwiftUI

struct Settings: View {
  @Query(CurrentUser()) var currentUser: User?

  @Environment(\.auth) var auth
  @EnvironmentObject private var ws: WebSocketManager
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var onboardingNav: OnboardingNavigation

  var body: some View {
    List {
      accountSection
      actionsSection
    }
    .listStyle(.plain)
  }
}

extension Settings {
  @ViewBuilder
  fileprivate var accountSection: some View {
    Section(header: Text("Account")) {
      if let currentUser = currentUser {
        HStack {
          UserAvatar(user: currentUser, size: 42)
            .padding(.trailing, 6)
          VStack(alignment: .leading) {
            Text((currentUser.firstName ?? "") + " " + (currentUser.lastName ?? ""))
              .font(.body)
              .fontWeight(.medium)
            Text(currentUser.email ?? "")
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }

      } else {
        Button("Set up profile") {
          // TODO: Add profile setup
        }
      }

    }
  }

  @ViewBuilder
  fileprivate var actionsSection: some View {
    Section(header: Text("Actions")) {
      Button("Logout", role: .destructive) {
        // Clear creds
        Auth.shared.logOut()

        // Stop WebSocket
        ws.loggedOut()

        // Clear database
        try? AppDatabase.loggedOut()

        nav.popToRoot()

        onboardingNav.push(.welcome)
      }
    }
  }
}

#Preview("Settings") {
  Settings()
    .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
}

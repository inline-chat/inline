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
  @EnvironmentObject private var mainViewRouter: MainViewRouter

  var body: some View {
    List {
      accountSection
      actionsSection
      apearenceSection
    }
    .listStyle(.plain)
  }
}

private extension Settings {
  @ViewBuilder
  var accountSection: some View {
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
  var actionsSection: some View {
    Section(header: Text("Actions")) {
      Button("Logout", role: .destructive) {
        // Clear creds
        Auth.shared.logOut()

        // Stop WebSocket
        ws.loggedOut()

        // Clear database
        try? AppDatabase.loggedOut()
        mainViewRouter.setRoute(route: .onboarding)
        nav.popToRoot()

        onboardingNav.push(.welcome)
      }
    }
  }

  @ViewBuilder
  var apearenceSection: some View {
    Section(header: Text("Appearance")) {
      BubbleColorSettings()
    }
  }
}

struct BubbleColorSettings: View {
  @State private var selectedColor: UIColor = BubbleColorManager.shared.selectedColor

  private let columns = [
    GridItem(.adaptive(minimum: 40), spacing: 12)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Bubble Color")
        .font(.headline)

      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(BubbleColorManager.shared.availableColors, id: \.self) { color in
          ZStack {
            Circle()
              .fill(Color(uiColor: color))
              .frame(width: 40, height: 40)
              .overlay(
                Circle()
                  .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
              )
              .onTapGesture {
                selectedColor = color
                BubbleColorManager.shared.saveColor(color)
              }
          }
        }
      }
    }
  }
}

#Preview("Settings") {
  Settings()
    .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
}

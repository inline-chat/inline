import GRDBQuery
import InlineKit
import SwiftUI

struct SettingsView: View {
  @Query(CurrentUser()) var currentUser: User?
  @Environment(\.auth) var auth
  @EnvironmentObject private var webSocket: WebSocketManager
  @EnvironmentObject private var navigation: Navigation
  @EnvironmentObject private var onboardingNavigation: OnboardingNavigation
  @EnvironmentObject private var mainRouter: MainViewRouter

  var body: some View {
    List {
      UserProfileSection(currentUser: currentUser)
      NavigationLink(destination: ThemeSection()) {
        HStack {
          Image(systemName: "paintbrush.fill")
            .foregroundColor(.white)
            .frame(width: 25, height: 25)
            .background(Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 6))
          Text("Appearance")
            .foregroundColor(.primary)
            .padding(.leading, 4)
          Spacer()
        }
        .padding(.vertical, 2)
      }
      LogoutSection()
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(id: "settings", placement: .principal) {
        HStack {
          Image(systemName: "gearshape.fill")
            .foregroundColor(.secondary)
            .font(.callout)
            .padding(.trailing, 4)
          VStack(alignment: .leading) {
            Text("Settings")
              .font(.body)
              .fontWeight(.semibold)
          }
        }
      }
    }
  }
}

#Preview("Settings") {
  SettingsView()
    .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
}

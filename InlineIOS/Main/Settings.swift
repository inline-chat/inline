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
      apearenceSection
      actionsSection
    }
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
        mainViewRouter.setRoute(route: .onboarding)
        nav.popToRoot()

        onboardingNav.push(.welcome)
      }
    }
  }

  @ViewBuilder
  fileprivate var apearenceSection: some View {
    Section(header: Text("Appearance")) {
      BubbleColorSettings()
    }
  }
}

struct BubbleColorPreview: View {
  let color: UIColor

  var body: some View {
    VStack(spacing: 12) {
      // Outgoing message bubble
      HStack {
        Spacer()
        Text("Hey there! This is how your messages will look")
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color(uiColor: color))
          .foregroundColor(.white)
          .cornerRadius(16)
          .padding(.trailing, 8)
          .fontWeight(.medium)
      }

      // Incoming message bubble
      HStack {
        Text("This is a reply message")
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color(.systemGray6))
          .cornerRadius(16)
          .padding(.leading, 8)
          .fontWeight(.medium)
        Spacer()
      }
    }
    .padding()
  }
}

struct BubbleColorSettings: View {
  @State private var selectedColor: UIColor = ColorManager.shared.selectedColor

  private let columns = [
    GridItem(.adaptive(minimum: 40), spacing: 10)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Accent Color")
        .font(.headline)

      // Preview section
      VStack(alignment: .leading, spacing: 8) {
        BubbleColorPreview(color: selectedColor)
          .background(Color(.systemGray6).opacity(0.5))
          .cornerRadius(12)
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.5), value: selectedColor)
    .listRowSeparator(.hidden)

    // Color grid
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(ColorManager.shared.availableColors, id: \.self) { color in
        ZStack {
          Circle()
            .fill(Color(uiColor: color))
            .frame(width: 36, height: 36)
            .scaleEffect(selectedColor == color ? 1.1 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.5), value: selectedColor)

          Circle()
            .stroke(Color(uiColor: selectedColor), lineWidth: selectedColor == color ? 2 : 0)
            .frame(width: 46, height: 46)
            .opacity(selectedColor == color ? 1 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.5), value: selectedColor)
        }
        .buttonStyle(PlainButtonStyle())
        .onTapGesture {
          withAnimation {
            selectedColor = color
            ColorManager.shared.saveColor(color)

            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
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

#Preview {
  BubbleColorSettings()
    .padding()
}

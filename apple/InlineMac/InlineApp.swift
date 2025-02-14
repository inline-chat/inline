import GRDB
import GRDBQuery
import InlineKit
import RealtimeAPI
import Sentry
import SwiftUI

@main
struct InlineApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @StateObject var viewModel = MainWindowViewModel()
  @StateObject var ws = WebSocketManager()
  @StateObject var navigation: NavigationModel = .shared
  @StateObject var auth = Auth.shared
  @StateObject var overlay = OverlayManager()

  @Environment(\.openWindow) var openWindow

  init() {
    UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
  }

  var body: some Scene {
    // Note(@mo): Using Window here messes up with our title bar handling upon window re-open after close
    WindowGroup(id: "main") {
      MainWindow()
        .environmentObject(ws)
        .environmentObject(viewModel)
        .environmentObject(navigation)
        .environment(\.auth, auth)
        .appDatabase(AppDatabase.shared)
        .environmentObject(overlay)
        .environment(\.logOut, logOut)
        .environment(\.transactions, Transactions.shared)
        .environment(\.realtime, Realtime.shared)
        .environment(
          \.requestNotifications,
          appDelegate.notifications.requestNotifications
        )
    }
    .defaultSize(width: 900, height: 600)
    .windowStyle(
      viewModel.topLevelRoute == .onboarding ? .hiddenTitleBar : .init()
    )
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      MainWindowCommands(
        isLoggedIn: auth.isLoggedIn,
        navigation: navigation,
        logOut: logOut
      )
    }

    // Chat single window
    WindowGroup(for: Peer.self) { $peerId in
      AuthenticatedWindowWrapper {
        if let peerId {
          ChatView(peerId: peerId)
        } else {
          Text("No chat selected.")
        }
      }
      .environmentObject(ws)
      .environmentObject(viewModel)
      .environmentObject(overlay)
      .environment(\.auth, Auth.shared)
      .environment(\.logOut, logOut)
      .appDatabase(AppDatabase.shared)
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .defaultSize(width: 680, height: 600)

    Settings {
      SettingsView()
        .environmentObject(ws)
        .environmentObject(viewModel)
        .environment(\.auth, Auth.shared)
        .environment(\.logOut, logOut)
        .appDatabase(AppDatabase.shared)
        .environmentObject(overlay)
    }
  }

  // Resets all state and data
  func logOut() async {
    let _ = try? await ApiClient.shared.logout()

    // Clear creds
    Auth.shared.logOut()

    // Stop WebSocket
    ws.loggedOut()

    // Clear database
    try? AppDatabase.loggedOut()

    // Navigate outside of the app
    viewModel.navigate(.onboarding)

    // Reset internal navigation
    navigation.reset()

    // Close Settings
    if let window = NSApplication.shared.keyWindow {
      window.close()
    }
  }

  // -----
}

public extension EnvironmentValues {
  @Entry var logOut: () async -> Void = {}
}
